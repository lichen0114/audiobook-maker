//! Audiobook Maker — a native macOS front-end for the Kokoro TTS backend.
//!
//! The view lives in `app.native`; this file is the logic: `Model`, `Msg`,
//! `update` (with the effects channel), and the boot/spawn wiring that drives
//! `app.py` exactly like the Ink CLI does — spawn with flags, parse the
//! newline-delimited JSON event stream, fold it into the model.
//!
//! Architecture note: the effects channel caps argv at 16 and has no env/cwd
//! knob, so every backend invocation is routed through `/bin/sh -c` (see
//! shell.zig). Reads (preflight, EPUB inspection, the file picker) use
//! `.collect`; the conversion run streams stdout lines via `.lines`.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

const config = @import("config.zig");
const events = @import("events.zig");
const apple_host = @import("apple_host.zig");
const shell = @import("shell.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 1040;
const window_height: f32 = 700;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Audiobook Maker canvas", .accessibility_label = "Audiobook Maker", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Audiobook Maker",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// Effect keys. Reads use fixed keys; per-book effects offset by index.
const KEY_DETECT: u64 = 1; // boot: root + python + memory + preflight
const KEY_PANEL: u64 = 2; // osascript file picker
const KEY_FIREFORGET: u64 = 3; // notifications / reveal / rm — exit ignored
const KEY_LSDIR: u64 = 4; // list *.epub in a directory
const INSPECT_BASE: u64 = 1000;
const CONVERT_BASE: u64 = 2000; // dynamic attempt keys are allocated above this value
const KEY_LOAD: u64 = 5;
const KEY_SAVE: u64 = 6;
const KEY_VOICE: u64 = 7;
const KEY_DEST: u64 = 8;
const KEY_PLAYER: u64 = 9;
const KEY_SAVEFILE: u64 = 10;
const KEY_COVER_PICKER: u64 = 11;
const KEY_RELINK: u64 = 12;

const MAX_BOOKS = 24;
const MAX_CHECKS = 6;

// ------------------------------------------------------------- small strings

fn Str(comptime N: usize) type {
    return struct {
        buf: [N]u8 = undefined,
        len: usize = 0,

        const Self = @This();
        pub fn set(self: *Self, s: []const u8) void {
            const n = @min(s.len, N);
            @memcpy(self.buf[0..n], s[0..n]);
            self.len = n;
        }
        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
        pub fn eql(self: *const Self, s: []const u8) bool {
            return std.mem.eql(u8, self.slice(), s);
        }
    };
}

// ------------------------------------------------------------------ model

pub const Screen = enum { checking, setup, library, done };

/// Per-book lifecycle. Mirrors the CLI's JobStatus + inspection outcomes.
pub const Status = enum {
    pending, // added, not yet inspected
    inspecting,
    ready,
    resumable, // a compatible checkpoint exists
    blocked, // duplicate output path
    converting,
    complete,
    failed,
    skipped,
    paused,
    cancelled,
};

pub const Check = struct {
    name: Str(24) = .{},
    ok: bool = false,
    message: Str(96) = .{},
    fix: Str(96) = .{},
};

pub const BookSection = struct {
    id: Str(160) = .{},
    title: Str(180) = .{},
    excerpt: Str(360) = .{},
    word_count: u64 = 0,
    included: bool = true,
};
pub const SectionRow = struct { index: usize, title: []const u8, detail: []const u8, included: bool };
pub const Book = struct {
    id: u64 = 0,
    cfg: config.TtsConfig = .{},
    revision: u64 = 0,
    inspect_revision: u64 = 0,
    inspect_key: u64 = 0,
    convert_key: u64 = 0,
    preview_key: u64 = 0,
    cover_key: u64 = 0,
    request_key: u64 = 0,
    prepared_attempt: u64 = 0,
    pending_mode: config.RunMode = .inspect,
    cover_image: u64 = 0,
    stop_requested: bool = false,
    stop_as_cancelled: bool = false,
    preserve_complete: bool = false,
    sections: [events.MAX_SECTIONS]BookSection = [_]BookSection{.{}} ** events.MAX_SECTIONS,
    section_count: usize = 0,
    sections_loaded: bool = false,
    section_overflow: bool = false,
    cover_path: Str(1024) = .{},
    preview_path: Str(1024) = .{},
    title_override: Str(200) = .{},
    author_override: Str(160) = .{},
    cover_override: Str(1024) = .{},
    warning: Str(240) = .{},
    model_message: Str(240) = .{},
    input: Str(1024) = .{},
    output: Str(1024) = .{},
    title: Str(200) = .{},
    author: Str(160) = .{},
    resolved_backend: Str(16) = .{},
    has_cover: bool = false,
    total_chars: u64 = 0,
    total_chunks: u32 = 0,
    chapter_count: u32 = 0,
    ckpt_exists: bool = false,
    resume_compatible: bool = false,
    ckpt_completed: u32 = 0,
    ckpt_total: u32 = 0,
    resume_choice: bool = true,
    status: Status = .pending,
    // live conversion state
    phase: events.Phase = .parsing,
    cur_chunk: u32 = 0,
    run_total_chunks: u32 = 0,
    chunk_ms: u32 = 0,
    estimated_chunk_ms: f64 = 0,
    timing_samples: u32 = 0,
    last_progress_ms: u64 = 0,
    err: Str(200) = .{},

    fn displayTitle(self: *const Book) []const u8 {
        if (self.title.len > 0) return self.title.slice();
        return basename(self.input.slice());
    }
};

/// Rows the sidebar/done list iterate over (arena-built each rebuild).
pub const BookRow = struct {
    index: usize,
    title: []const u8,
    subtitle: []const u8,
    status: []const u8,
    pct: f32,
    selected: bool,
    converting: bool,
    failed: bool,
    has_cover: bool,
    cover_image: u64,
};

pub const CheckRow = struct {
    name: []const u8,
    message: []const u8,
    fix: []const u8,
    ok: bool,
    bad: bool,
};

pub const Model = struct {
    screen: Screen = .checking,

    checks: [MAX_CHECKS]Check = [_]Check{.{}} ** MAX_CHECKS,
    check_count: usize = 0,

    books: [MAX_BOOKS]Book = [_]Book{.{}} ** MAX_BOOKS,
    book_count: usize = 0,
    selected: usize = 0,
    next_book_id: u64 = 1,
    next_effect_key: u64 = 3000,
    inspect_key: u64 = 0,
    previewing: bool = false,
    playing: bool = false,
    queue_paused: bool = false,
    advanced: bool = false,
    sections_expanded: bool = false,
    voice_picker_book: u64 = 0,
    destination_book: u64 = 0,
    cover_picker_book: u64 = 0,
    relink_book: u64 = 0,
    queue_scope_id: u64 = 0,
    state_dir: Str(1024) = .{},
    output_directory: Str(1024) = .{},
    notice: Str(240) = .{},
    state_loaded: bool = false,
    saving: bool = false,
    save_pending: bool = false,
    state_readonly: bool = false,
    title_buf: canvas.TextBuffer(200) = .{},
    author_buf: canvas.TextBuffer(160) = .{},

    // Batch-level configuration (applies to every book).
    cfg: config.TtsConfig = .{},
    voice_index: usize = 0,
    speed_index: usize = 2, // 1.0x

    // conversion queue
    converting: bool = false,
    active: usize = 0,
    inspect_in_flight: bool = false,
    started_ms: u64 = 0,
    total_ms: u64 = 0,

    // path entry field
    path_buf: canvas.TextBuffer(1024) = .{},

    // resolved runtime (filled by the boot detection script)
    py_ok: bool = false,
    low_mem: bool = false,
    bundled: bool = false, // running inside a packaged .app (MLX-only)
    python: Str(1024) = .{},
    app_py: Str(1024) = .{},
    root: Str(1024) = .{},
    res_dir: Str(1024) = .{}, // <App>.app/Contents/Resources when bundled

    pub const view_unbound = .{
        "python",            "py_ok",             "low_mem",           "bundled",
        "app_py",            "root",              "res_dir",           "started_ms",
        "active",            "total_ms",          "inspect_in_flight", "check_count",
        "book_count",        "voice_index",       "speed_index",       "checks",
        "books",             "cfg",               "path_buf",          "screen",
        "selected",          "next_book_id",      "next_effect_key",   "inspect_key",
        "previewing",        "playing",           "queue_paused",      "advanced",
        "sections_expanded", "voice_picker_book", "destination_book",  "cover_picker_book",
        "relink_book",       "queue_scope_id",    "state_dir",         "output_directory",
        "notice",            "state_loaded",      "saving",            "save_pending",
        "state_readonly",    "title_buf",         "author_buf",
    };

    // ---- derived screen predicates (markup <if> bindings) ----
    pub fn isChecking(self: *const Model) bool {
        return self.screen == .checking;
    }
    pub fn isSetup(self: *const Model) bool {
        return self.screen == .setup;
    }
    pub fn isLibrary(self: *const Model) bool {
        return self.screen == .library;
    }
    pub fn isDone(self: *const Model) bool {
        return self.screen == .done;
    }
    pub fn hasBooks(self: *const Model) bool {
        return self.book_count > 0;
    }

    // ---- preflight ----
    pub fn checkRows(self: *const Model, arena: std.mem.Allocator) []const CheckRow {
        const out = arena.alloc(CheckRow, self.check_count) catch return &.{};
        for (0..self.check_count) |i| {
            out[i] = .{
                .name = self.checks[i].name.slice(),
                .message = self.checks[i].message.slice(),
                .fix = self.checks[i].fix.slice(),
                .ok = self.checks[i].ok,
                .bad = !self.checks[i].ok,
            };
        }
        return out;
    }

    // ---- library rows ----
    pub fn bookRows(self: *const Model, arena: std.mem.Allocator) []const BookRow {
        const out = arena.alloc(BookRow, self.book_count) catch return &.{};
        for (0..self.book_count) |i| {
            const b = &self.books[i];
            out[i] = .{
                .index = i,
                .title = b.displayTitle(),
                .subtitle = if (b.author.len > 0) b.author.slice() else "Unknown author",
                .status = statusLine(b, arena),
                .pct = pct(b),
                .selected = (i == self.selected),
                .converting = (b.status == .converting),
                .failed = (b.status == .failed),
                .has_cover = b.cover_image != 0,
                .cover_image = b.cover_image,
            };
        }
        return out;
    }

    pub fn statusText(self: *const Model, arena: std.mem.Allocator) []const u8 {
        if (self.notice.len > 0) return self.notice.slice();
        if (self.previewing) {
            for (self.books[0..self.book_count]) |*book| {
                if (book.preview_key > 0) return std.fmt.allocPrint(arena, "Preview · {s}", .{if (book.model_message.len > 0) book.model_message.slice() else book.phase.label()}) catch "Preparing preview…";
            }
        }
        if (self.queue_paused and !self.converting) return "Queue paused · choose Create All to continue";
        if (self.converting) {
            const b = &self.books[self.active];
            return std.fmt.allocPrint(arena, "Converting {s} — {s} · {d}% · {s}", .{
                b.displayTitle(), if (b.model_message.len > 0) b.model_message.slice() else b.phase.label(), pctInt(b), remainingLabel(b, native_sdk.monotonicMs(), arena),
            }) catch "Converting…";
        }
        var ready: usize = 0;
        var resumable: usize = 0;
        for (0..self.book_count) |i| {
            switch (self.books[i].status) {
                .ready => ready += 1,
                .resumable => resumable += 1,
                else => {},
            }
        }
        if (self.book_count == 0) return "Add an EPUB to begin";
        return std.fmt.allocPrint(arena, "{d} book(s) · {d} ready · {d} resumable", .{
            self.book_count, ready, resumable,
        }) catch "";
    }

    pub fn canConvert(self: *const Model) bool {
        if (self.converting or self.previewing or self.inspect_in_flight or !self.state_loaded) return false;
        for (0..self.book_count) |i| {
            switch (self.books[i].status) {
                .ready, .resumable, .paused, .cancelled => return true,
                else => {},
            }
        }
        return false;
    }

    pub fn pathDraft(self: *const Model) []const u8 {
        return self.path_buf.text();
    }

    // ---- selected book ----
    fn sel(self: *const Model) ?*const Book {
        if (self.book_count == 0 or self.selected >= self.book_count) return null;
        return &self.books[self.selected];
    }
    pub fn selValid(self: *const Model) bool {
        return self.sel() != null;
    }
    pub fn selTitle(self: *const Model) []const u8 {
        return if (self.sel()) |b| b.displayTitle() else "";
    }
    pub fn selAuthor(self: *const Model) []const u8 {
        return if (self.sel()) |b| (if (b.author.len > 0) b.author.slice() else "Unknown author") else "";
    }
    pub fn selMeta(self: *const Model, arena: std.mem.Allocator) []const u8 {
        const b = self.sel() orelse return "";
        if (b.total_chunks == 0) return "Inspecting…";
        return std.fmt.allocPrint(arena, "{d} sections · about {d} min listening · ~{d} MB temporary space", .{
            b.chapter_count, @max(1, b.total_chars / 900), @max(1, b.total_chars / 900) * 6,
        }) catch "";
    }
    pub fn selStatus(self: *const Model, arena: std.mem.Allocator) []const u8 {
        const b = self.sel() orelse return "";
        if (b.preview_key > 0) return if (b.model_message.len > 0) b.model_message.slice() else b.phase.label();
        return statusLine(b, arena);
    }
    pub fn selHasError(self: *const Model) bool {
        return if (self.sel()) |b| b.err.len > 0 else false;
    }
    pub fn selError(self: *const Model) []const u8 {
        return if (self.sel()) |b| b.err.slice() else "";
    }
    pub fn selResumable(self: *const Model) bool {
        return if (self.sel()) |b| (b.status == .resumable) else false;
    }
    pub fn selResumeChosen(self: *const Model) bool {
        return if (self.sel()) |b| b.resume_choice else false;
    }
    pub fn selCkpt(self: *const Model, arena: std.mem.Allocator) []const u8 {
        const b = self.sel() orelse return "";
        return std.fmt.allocPrint(arena, "Saved speech: {d}% ready. Continue without repeating completed narration.", .{
            if (b.ckpt_total > 0) @as(u64, b.ckpt_completed) * 100 / b.ckpt_total else 0,
        }) catch "";
    }
    pub fn selConverting(self: *const Model) bool {
        return if (self.sel()) |b| (b.status == .converting) else false;
    }
    pub fn selPct(self: *const Model) f32 {
        return if (self.sel()) |b| pct(b) else 0;
    }
    pub fn selEta(self: *const Model, arena: std.mem.Allocator) []const u8 {
        const b = self.sel() orelse return "";
        return remainingLabel(b, native_sdk.monotonicMs(), arena);
    }

    pub fn pauseLabel(self: *const Model) []const u8 {
        return if (self.converting and self.books[self.active].cfg.checkpoint_enabled) "Pause and Save" else "Stop Queue";
    }
    pub fn cfgEditable(self: *const Model) bool {
        return !self.converting and !self.previewing;
    }
    pub fn showAdvanced(self: *const Model) bool {
        return self.advanced;
    }
    pub fn selWarning(self: *const Model) []const u8 {
        return if (self.sel()) |b| b.warning.slice() else "";
    }
    pub fn selHasWarning(self: *const Model) bool {
        return self.selWarning().len > 0;
    }
    pub fn selOutput(self: *const Model) []const u8 {
        return if (self.sel()) |b| b.output.slice() else "";
    }
    pub fn titleDraft(self: *const Model) []const u8 {
        return self.title_buf.text();
    }
    pub fn authorDraft(self: *const Model) []const u8 {
        return self.author_buf.text();
    }
    pub fn canPreview(self: *const Model) bool {
        const b = self.sel() orelse return false;
        return self.cfgEditable() and !self.inspect_in_flight and (b.status == .ready or b.status == .resumable or b.status == .complete);
    }
    pub fn canPlay(self: *const Model) bool {
        const b = self.sel() orelse return false;
        return b.status == .complete;
    }
    pub fn canPlayPreview(self: *const Model) bool {
        return if (self.sel()) |b| b.preview_path.len > 0 else false;
    }
    pub fn canConvertSelected(self: *const Model) bool {
        const b = self.sel() orelse return false;
        return self.canConvert() and (b.status == .ready or b.status == .resumable or b.status == .paused);
    }
    pub fn canRetry(self: *const Model) bool {
        const b = self.sel() orelse return false;
        return self.cfgEditable() and (b.status == .failed or b.status == .cancelled or b.status == .paused);
    }
    pub fn selHasCover(self: *const Model) bool {
        return if (self.sel()) |b| b.cover_image != 0 else false;
    }
    pub fn selCover(self: *const Model) u64 {
        return if (self.sel()) |b| b.cover_image else 0;
    }
    pub fn sectionsExpanded(self: *const Model) bool {
        return self.sections_expanded;
    }
    pub fn selHasSections(self: *const Model) bool {
        return if (self.sel()) |b| b.section_count > 0 else false;
    }
    pub fn sectionRows(self: *const Model, arena: std.mem.Allocator) []const SectionRow {
        const b = self.sel() orelse return &.{};
        const rows = arena.alloc(SectionRow, b.section_count) catch return &.{};
        for (rows, 0..) |*row, i| {
            const section = &b.sections[i];
            row.* = .{ .index = i, .title = section.title.slice(), .detail = std.fmt.allocPrint(arena, "{d} words · {s}", .{ section.word_count, section.excerpt.slice() }) catch "", .included = section.included };
        }
        return rows;
    }

    // ---- config labels / flags ----
    pub fn voiceLabel(self: *const Model) []const u8 {
        return config.voices[self.voice_index].label;
    }
    pub fn accentLabel(self: *const Model) []const u8 {
        return switch (config.voices[self.voice_index].accent) {
            .a => "American",
            .b => "British",
        };
    }
    pub fn speedLabel(self: *const Model, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "{d}x", .{config.speeds[self.speed_index]}) catch "1.0x";
    }
    pub fn isMp3(self: *const Model) bool {
        return self.cfg.format == .mp3;
    }
    pub fn isM4b(self: *const Model) bool {
        return self.cfg.format == .m4b;
    }
    pub fn br128(self: *const Model) bool {
        return self.cfg.bitrate == .k128;
    }
    pub fn br192(self: *const Model) bool {
        return self.cfg.bitrate == .k192;
    }
    pub fn br320(self: *const Model) bool {
        return self.cfg.bitrate == .k320;
    }
    pub fn beAuto(self: *const Model) bool {
        return self.cfg.backend == .auto;
    }
    pub fn bePytorch(self: *const Model) bool {
        return self.cfg.backend == .pytorch;
    }
    pub fn beMlx(self: *const Model) bool {
        return self.cfg.backend == .mlx;
    }
    pub fn cfgNormalize(self: *const Model) bool {
        return self.cfg.normalize;
    }
    pub fn cfgGpu(self: *const Model) bool {
        return self.cfg.use_mps;
    }
    pub fn cfgCheckpoint(self: *const Model) bool {
        return self.cfg.checkpoint_enabled;
    }
    pub fn showGpu(self: *const Model) bool {
        return self.cfg.backend != .mlx;
    }
    /// A packaged .app ships MLX only, so the backend picker is hidden there.
    pub fn showBackend(self: *const Model) bool {
        return !self.bundled;
    }

    // ---- done screen ----
    pub fn doneSummary(self: *const Model, arena: std.mem.Allocator) []const u8 {
        var complete: usize = 0;
        var failed: usize = 0;
        for (0..self.book_count) |i| {
            switch (self.books[i].status) {
                .complete => complete += 1,
                .failed, .skipped, .blocked, .cancelled => failed += 1,
                else => {},
            }
        }
        return std.fmt.allocPrint(arena, "{d} completed · {d} with issues · {d:.1}s", .{
            complete, failed, @as(f64, @floatFromInt(self.total_ms)) / 1000.0,
        }) catch "";
    }
};

fn pct(b: *const Book) f32 {
    if (b.run_total_chunks == 0) return 0;
    return @as(f32, @floatFromInt(b.cur_chunk)) / @as(f32, @floatFromInt(b.run_total_chunks));
}
fn pctInt(b: *const Book) u32 {
    return @intFromFloat(pct(b) * 100.0);
}

fn recordTiming(book: *Book, ms: u32) void {
    if (ms == 0) return;
    book.chunk_ms = ms;
    const measured: f64 = @floatFromInt(ms);
    book.estimated_chunk_ms = if (book.timing_samples == 0) measured else 0.25 * measured + 0.75 * book.estimated_chunk_ms;
    book.timing_samples +|= 1;
}

fn remainingMs(book: *const Book, now: u64) ?u64 {
    if (book.phase != .inference or book.timing_samples < 2 or book.run_total_chunks <= book.cur_chunk) return null;
    const outstanding: f64 = @floatFromInt(book.run_total_chunks - book.cur_chunk);
    const elapsed: f64 = @floatFromInt(now -| book.last_progress_ms);
    // Never extrapolate an overlong current chunk into negative remaining time.
    const ms = outstanding * book.estimated_chunk_ms - @min(elapsed, book.estimated_chunk_ms);
    return @intFromFloat(@ceil(@max(0, ms)));
}

fn remainingLabel(book: *const Book, now: u64, arena: std.mem.Allocator) []const u8 {
    if (book.stop_requested) return "Pausing…";
    if (book.phase == .concatenating or book.phase == .exporting or book.phase == .done or
        (book.phase == .inference and book.run_total_chunks > 0 and book.cur_chunk >= book.run_total_chunks)) return "Finishing audiobook…";
    const ms = remainingMs(book, now) orelse return "Estimating time remaining…";
    if (ms < 60000) return "Less than a minute of narration left";
    const minutes = (ms + 59999) / 60000;
    if (minutes >= 60) return std.fmt.allocPrint(arena, "About {d} h {d} min of narration left", .{ minutes / 60, minutes % 60 }) catch "Estimating time remaining…";
    return std.fmt.allocPrint(arena, "About {d} min of narration left", .{minutes}) catch "Estimating time remaining…";
}

fn statusLine(b: *const Book, arena: std.mem.Allocator) []const u8 {
    return switch (b.status) {
        .pending, .inspecting => "Inspecting…",
        .ready => "Ready to create",
        .resumable => std.fmt.allocPrint(arena, "Saved speech · {d}% ready", .{if (b.ckpt_total > 0) @as(u64, b.ckpt_completed)*100/b.ckpt_total else 0}) catch "Saved progress",
        .blocked => "Blocked · duplicate output",
        .converting => std.fmt.allocPrint(arena, "{s} · {d}%", .{ if (b.model_message.len > 0) b.model_message.slice() else b.phase.label(), pctInt(b) }) catch "Converting",
        .complete => "Done",
        .failed => std.fmt.allocPrint(arena, "Failed: {s}", .{b.err.slice()}) catch "Failed",
        .skipped => "Skipped",
        .paused => "Paused",
        .cancelled => "Cancelled",
    };
}

fn basename(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

fn thousands(arena: std.mem.Allocator, n: u64) []const u8 {
    var tmp: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return "";
    const digits = s.len;
    if (digits <= 3) return arena.dupe(u8, s) catch s;
    const commas = (digits - 1) / 3;
    const out = arena.alloc(u8, digits + commas) catch return arena.dupe(u8, s) catch s;
    var oi: usize = 0;
    for (s, 0..) |c, i| {
        if (i != 0 and (digits - i) % 3 == 0) {
            out[oi] = ',';
            oi += 1;
        }
        out[oi] = c;
        oi += 1;
    }
    return out;
}

// -------------------------------------------------------------------- msg

pub const Msg = union(enum) {
    // effect completions
    effect_line: native_sdk.EffectLine,
    effect_exit: native_sdk.EffectExit,
    file_result: native_sdk.EffectFileResult,
    // preflight
    retry_checks,
    // library
    add_books, // opens the native file picker
    path_edit: canvas.TextInputEvent,
    add_path, // submit the typed path
    select_book: usize,
    remove_selected,
    // config
    cycle_voice,
    pick_voice,
    toggle_advanced,
    toggle_sections,
    preview_book,
    play_audio,
    play_preview,
    apply_all,
    choose_cover,
    relink_source,
    retry_selected,
    choose_destination,
    cancel_preview,
    slower_speed,
    faster_speed,
    title_edit: canvas.TextInputEvent,
    author_edit: canvas.TextInputEvent,
    apply_metadata,
    toggle_section: usize,
    cycle_speed,
    set_mp3,
    set_m4b,
    set_auto,
    set_pytorch,
    set_mlx,
    set_br128,
    set_br192,
    set_br320,
    toggle_normalize,
    toggle_gpu,
    toggle_checkpoint,
    toggle_resume,
    // queue
    convert_all,
    convert_selected,
    skip_book,
    cancel_convert,
    reveal_output,
    new_batch,

    // dispatched by the runtime effects channel, not the view
    pub const view_unbound = .{ "effect_line", "effect_exit", "file_result", "cycle_voice", "cycle_speed" };
};

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

const App = native_sdk.UiApp(Model, Msg);
const Effects = App.Effects;

// --------------------------------------------------------------- lifecycle

extern "c" fn arc4random() u32;
pub fn initialModel() Model {
    // Attempt identities stay unique across launches, including system reboots.
    const seed = ((@as(u64, arc4random()) << 32) | @as(u64, arc4random())) & 0x7fffffffffffffff;
    return .{ .next_effect_key = @max(3000, seed) };
}

/// Read an environment variable as a slice (libc-backed; the app links libc).
fn getenvSlice(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}

fn boot(model: *Model, fx: *Effects) void {
    model.cfg.use_mps = apple_host.defaultUseMps();
    detectBundle(model);
    // Open-with-file seam: launch with a book already loaded (also the
    // deterministic entry point for automated end-to-end tests).
    if (getenvSlice("AUDIOBOOK_ADD_EPUB")) |p| {
        if (std.ascii.endsWithIgnoreCase(p, ".epub")) addBook(model, p);
    }
    model.screen = .checking; // stays here until detection resolves
    startDetect(model, fx);
}

// dyld gives us the executable path without argv (removed in std 0.16).
extern "c" fn _NSGetExecutablePath(buf: [*c]u8, bufsize: *u32) c_int;

/// When launched from inside `<App>.app/Contents/MacOS/<bin>`, derive the
/// sibling `Resources/` dir that holds the embedded Python + backend + ffmpeg.
fn detectBundle(model: *Model) void {
    var path_buf: [1024]u8 = undefined;
    var size: u32 = @intCast(path_buf.len);
    const rc = _NSGetExecutablePath(&path_buf, &size);
    if (rc != 0) return;
    const a0 = std.mem.sliceTo(&path_buf, 0);
    const marker = "/Contents/MacOS/";
    const i = std.mem.indexOf(u8, a0, marker) orelse return;
    var res_buf: [1024]u8 = undefined;
    const res = std.fmt.bufPrint(&res_buf, "{s}/Contents/Resources", .{a0[0..i]}) catch return;
    model.res_dir.set(res);
    model.bundled = true;
    model.cfg.backend = .mlx; // packaged app ships the MLX runtime only
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    const config_message = switch (msg) {
        .cycle_voice, .cycle_speed, .slower_speed, .faster_speed, .set_mp3, .set_m4b, .set_auto, .set_pytorch, .set_mlx, .set_br128, .set_br192, .set_br320, .toggle_normalize, .toggle_gpu, .toggle_checkpoint => true,
        else => false,
    };
    if (config_message and !model.cfgEditable()) return;
    switch (msg) {
        .effect_line => |line| onLine(model, line),
        .effect_exit => |exit| onExit(model, exit, fx),
        .file_result => |result| onFile(model, result, fx),

        .retry_checks => {
            model.screen = .checking;
            startDetect(model, fx);
        },

        .add_books => openPicker(model, fx),
        .path_edit => |edit| model.path_buf.apply(edit),
        .add_path => {
            const text = model.path_buf.text();
            if (std.ascii.endsWithIgnoreCase(std.mem.trim(u8, text, " \t\r\n\"'"), ".epub")) {
                addFromText(model, text);
                ensureInspecting(model, fx);
            } else {
                listDir(model, std.mem.trim(u8, text, " \t\r\n\"'"), fx);
            }
            model.path_buf.clear();
        },
        .select_book => |i| {
            if (i < model.book_count) {
                model.selected = i;
                syncSelection(model);
            }
        },
        .remove_selected => removeSelected(model, fx),

        .pick_voice => pickVoice(model, fx),
        .toggle_advanced => model.advanced = !model.advanced,
        .toggle_sections => model.sections_expanded = !model.sections_expanded,
        .title_edit => |edit| model.title_buf.apply(edit),
        .author_edit => |edit| model.author_buf.apply(edit),
        .apply_metadata => {
            if (model.cfgEditable() and model.selected < model.book_count) {
                const b = &model.books[model.selected];
                b.title_override.set(model.title_buf.text());
                b.author_override.set(model.author_buf.text());
                invalidateBook(model, model.selected, fx);
            }
        },
        .toggle_section => |index| {
            if (model.cfgEditable() and model.selected < model.book_count) {
                const b = &model.books[model.selected];
                if (index < b.section_count and !b.section_overflow) {
                    b.sections[index].included = !b.sections[index].included;
                    invalidateBook(model, model.selected, fx);
                }
            }
        },
        .choose_destination => chooseDestination(model, fx),
        .cancel_preview => {
            if (model.previewing) {
                for (model.books[0..model.book_count]) |*book| {
                    if (book.preview_key > 0) {
                        book.stop_requested = true;
                        requestStop(model, book, fx);
                        break;
                    }
                }
            }
        },
        .slower_speed => {
            if (model.speed_index > 0) model.speed_index -= 1;
            model.cfg.speed = config.speeds[model.speed_index];
        },
        .faster_speed => {
            if (model.speed_index + 1 < config.speeds.len) model.speed_index += 1;
            model.cfg.speed = config.speeds[model.speed_index];
        },
        .preview_book => {
            if (model.canPreview()) {
                model.notice.len = 0;
                model.previewing = true;
                const b = &model.books[model.selected];
                b.preview_path.len = 0;
                b.err.len = 0;
                b.model_message.len = 0;
                b.phase = .parsing;
                spawnBackend(model, model.selected, .preview, fx);
            }
        },
        .play_audio => playAudio(model, false, fx),
        .play_preview => playAudio(model, true, fx),
        .choose_cover => {
            if (model.cfgEditable() and model.selected < model.book_count) {
                model.cover_picker_book = model.books[model.selected].id;
                scriptEffect(KEY_COVER_PICKER, "try\nreturn POSIX path of (choose file with prompt \"Choose audiobook cover art\" of type {\"public.image\"})\non error message number code\nif code is -128 then return \"\"\nerror message number code\nend try", fx);
            }
        },
        .relink_source => {
            if (model.cfgEditable() and model.selected < model.book_count) {
                model.relink_book = model.books[model.selected].id;
                scriptEffect(KEY_RELINK, "try\nreturn POSIX path of (choose file with prompt \"Locate this EPUB book\")\non error message number code\nif code is -128 then return \"\"\nerror message number code\nend try", fx);
            }
        },
        .apply_all => {
            if (model.cfgEditable() and model.selected < model.book_count) {
                for (0..model.book_count) |i| {
                    const book = &model.books[i];
                    if (i == model.selected or book.status == .complete) continue;
                    book.cfg = model.cfg;
                    const old = book.output.slice();
                    const dot = std.mem.lastIndexOfScalar(u8, old, '.') orelse old.len;
                    var path: [1100]u8 = undefined;
                    book.output.set(std.fmt.bufPrint(&path, "{s}{s}", .{ old[0..dot], model.cfg.format.ext() }) catch continue);
                    invalidateBook(model, i, fx);
                }
                model.notice.set("Voice, speed and output settings applied to all unstarted books.");
            }
        },
        .retry_selected => {
            if (model.canRetry()) invalidateBook(model, model.selected, fx);
        },
        .cycle_voice => {
            model.voice_index = (model.voice_index + 1) % config.voices.len;
            model.cfg.voice = config.voices[model.voice_index].id;
            model.cfg.accent = config.voices[model.voice_index].accent;
        },
        .cycle_speed => {
            model.speed_index = (model.speed_index + 1) % config.speeds.len;
            model.cfg.speed = config.speeds[model.speed_index];
        },
        .set_mp3 => setFormat(model, .mp3, fx),
        .set_m4b => setFormat(model, .m4b, fx),
        .set_auto => model.cfg.backend = .auto,
        .set_pytorch => model.cfg.backend = .pytorch,
        .set_mlx => {
            model.cfg.backend = .mlx;
            model.cfg.use_mps = true;
        },
        .set_br128 => model.cfg.bitrate = .k128,
        .set_br192 => model.cfg.bitrate = .k192,
        .set_br320 => model.cfg.bitrate = .k320,
        .toggle_normalize => model.cfg.normalize = !model.cfg.normalize,
        .toggle_gpu => model.cfg.use_mps = !model.cfg.use_mps,
        .toggle_checkpoint => model.cfg.checkpoint_enabled = !model.cfg.checkpoint_enabled,
        .toggle_resume => {
            if (model.selected < model.book_count) {
                const b = &model.books[model.selected];
                if (b.status == .resumable) b.resume_choice = !b.resume_choice;
            }
        },

        .convert_all => {
            if (model.canConvert()) {
                model.notice.len = 0;
                model.queue_paused = false;
                model.queue_scope_id = 0;
                for (0..model.book_count) |i| {
                    if (model.books[i].status == .paused or model.books[i].status == .cancelled) model.books[i].status = .ready;
                }
                model.started_ms = native_sdk.monotonicMs();
                startNextConvert(model, fx);
            }
        },
        .convert_selected => {
            if (model.canConvertSelected()) {
                model.notice.len = 0;
                model.queue_paused = false;
                model.queue_scope_id = model.books[model.selected].id;
                if (model.books[model.selected].status == .paused) model.books[model.selected].status = .ready;
                model.started_ms = native_sdk.monotonicMs();
                startNextConvert(model, fx);
            }
        },
        .skip_book => {
            if (model.converting) {
                const book = &model.books[model.active];
                book.stop_requested = true;
                book.stop_as_cancelled = true;
                requestStop(model, book, fx);
            }
        },
        .cancel_convert => {
            model.queue_paused = true;
            if (model.converting) {
                const book = &model.books[model.active];
                book.stop_requested = true;
                book.stop_as_cancelled = false;
                requestStop(model, book, fx);
                // The exit acknowledgement owns the transition; never start another process here.
            }
        },
        .reveal_output => revealSelected(model, fx),
        .new_batch => {
            model.screen = .library;
        },
    }
    if (config_message and model.selected < model.book_count) {
        model.books[model.selected].cfg = model.cfg;
        invalidateBook(model, model.selected, fx);
    }
    switch (msg) {
        .effect_line, .file_result, .title_edit, .author_edit, .path_edit => {},
        .effect_exit => |exit| {
            if (exit.key != KEY_SAVE) saveLibrary(model, fx);
        },
        else => saveLibrary(model, fx),
    }
}

// ---------------------------------------------------------- effect handlers

fn onLine(model: *Model, line: native_sdk.EffectLine) void {
    const idx = bookForEffect(model, line.key) orelse return;
    const b = &model.books[idx];
    if (line.key != b.convert_key and line.key != b.preview_key) return;

    var scratch: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const ev = events.parseLine(fba.allocator(), line.line) orelse return;
    switch (ev) {
        .phase => |p| {
            b.phase = p;
            if (p == .inference) b.last_progress_ms = native_sdk.monotonicMs();
            if (p == .inference or p == .exporting or p == .done) b.model_message.len = 0;
        },
        .progress => |pr| {
            b.cur_chunk = pr.current;
            b.run_total_chunks = pr.total;
            b.last_progress_ms = native_sdk.monotonicMs();
        },
        .timing => |ms| recordTiming(b, ms),
        .model_progress => |progress| {
            if (progress.total > 0) {
                var buf: [300]u8 = undefined;
                b.model_message.set(std.fmt.bufPrint(&buf, "{s} · {d}/{d} MB", .{ progress.message, progress.downloaded / 1000000, progress.total / 1000000 }) catch progress.message);
            } else b.model_message.set(progress.message);
        },
        .err => |m| b.err.set(m),
        .done => |done| {
            if (done.output.len > 0) {
                if (line.key == b.preview_key) b.preview_path.set(done.output) else b.output.set(done.output);
            }
        },
        .log => |log| {
            if (std.ascii.eqlIgnoreCase(log.level, "warning")) b.warning.set(log.message);
        },
        else => {},
    }
}

fn onExit(model: *Model, exit: native_sdk.EffectExit, fx: *Effects) void {
    if (exit.key == KEY_DETECT) {
        applyDetect(model, exit.output, fx);
        return;
    }
    if (exit.key == KEY_PANEL or exit.key == KEY_LSDIR) {
        if (exit.reason == .exited and exit.code == 0) {
            addFromText(model, exit.output);
            ensureInspecting(model, fx);
        }
        return;
    }
    if (exit.key == KEY_FIREFORGET) return;

    if (exit.key == KEY_LOAD) {
        restoreLibrary(model, exit.output);
        model.state_loaded = true;
        ensureInspecting(model, fx);
        return;
    }
    if (exit.key == KEY_SAVE) {
        model.saving = false;
        if (exit.code != 0) model.notice.set("Could not save the library. Check available disk space.");
        if (model.save_pending) {
            model.save_pending = false;
            saveLibrary(model, fx);
        }
        return;
    }
    if (exit.key == KEY_VOICE and exit.code != 0) {
        model.notice.set(shortError(exit.stderr_tail));
        return;
    }
    if ((exit.key == KEY_DEST or exit.key == KEY_COVER_PICKER or exit.key == KEY_RELINK) and exit.code != 0) {
        model.notice.set(shortError(exit.stderr_tail));
        return;
    }
    if (exit.key == KEY_VOICE) {
        if (exit.code == 0) {
            if (bookIndex(model, model.voice_picker_book)) |idx| {
                const text = std.mem.trim(u8, exit.output, " \r\n");
                for (config.voices, 0..) |voice, vi| {
                    if (std.mem.eql(u8, text, voice.label)) {
                        model.books[idx].cfg.voice = voice.id;
                        model.books[idx].cfg.accent = voice.accent;
                        model.selected = idx;
                        model.voice_index = vi;
                        syncSelection(model);
                        invalidateBook(model, idx, fx);
                        break;
                    }
                }
            }
        }
        return;
    }
    if (exit.key == KEY_DEST) {
        if (exit.code == 0) {
            if (bookIndex(model, model.destination_book)) |idx| {
                const dir = std.mem.trim(u8, exit.output, " \r\n");
                if (dir.len > 0) {
                    model.output_directory.set(dir);
                    var buf: [1200]u8 = undefined;
                    const name = basename(model.books[idx].input.slice());
                    const stem = if (name.len > 5) name[0 .. name.len - 5] else name;
                    model.books[idx].output.set(std.fmt.bufPrint(&buf, "{s}/{s}{s}", .{ std.mem.trimEnd(u8, dir, "/"), stem, model.books[idx].cfg.format.ext() }) catch return);
                    invalidateBook(model, idx, fx);
                }
            }
        }
        return;
    }
    if (exit.key == KEY_COVER_PICKER or exit.key == KEY_RELINK) {
        const id = if (exit.key == KEY_COVER_PICKER) model.cover_picker_book else model.relink_book;
        if (exit.code == 0) {
            if (bookIndex(model, id)) |idx| {
                const path = std.mem.trim(u8, exit.output, " \r\n");
                if (path.len > 0) {
                    const book = &model.books[idx];
                    if (exit.key == KEY_COVER_PICKER) {
                        book.cover_override.set(path);
                        book.cover_image = 0;
                    } else if (std.ascii.endsWithIgnoreCase(path, ".epub")) book.input.set(path) else {
                        model.notice.set("Choose an EPUB file to relink this book.");
                        return;
                    }
                    invalidateBook(model, idx, fx);
                }
            }
        }
        return;
    }
    if (exit.key == KEY_PLAYER) {
        model.playing = false;
        return;
    }
    const idx = bookForEffect(model, exit.key);
    if (exit.key == model.inspect_key) {
        model.inspect_key = 0;
        model.inspect_in_flight = false;
        if (idx) |i| {
            const b = &model.books[i];
            if (b.inspect_revision == b.revision) applyInspection(model, i, exit, fx);
            b.inspect_key = 0;
        }
        ensureInspecting(model, fx);
        return;
    }
    const i = idx orelse return; // completion from a removed book / obsolete attempt
    const book = &model.books[i];
    if (exit.key == book.preview_key) {
        book.preview_key = 0;
        model.previewing = false;
        if (book.stop_requested) {
            book.stop_requested = false;
            book.err.len = 0;
            book.preview_path.len = 0;
        } else if (exit.reason != .exited or exit.code != 0) {
            book.preview_path.len = 0;
            if (book.err.len == 0) book.err.set("Preview could not finish. Retry after checking the voice model download.");
        }
        ensureInspecting(model, fx);
        return;
    }
    if (exit.key != book.convert_key) return;
    book.convert_key = 0;
    model.converting = false;
    if (book.stop_requested) {
        book.stop_requested = false;
        book.err.len = 0;
        if (book.stop_as_cancelled) {
            book.status = .cancelled;
            book.stop_as_cancelled = false;
        } else {
            book.status = .paused;
            invalidateBook(model, i, fx);
        }
    } else if (exit.reason == .exited and exit.code == 0) {
        book.status = .complete;
        book.cur_chunk = book.run_total_chunks;
    } else {
        book.status = .failed;
        if (book.err.len == 0) book.err.set(shortError(exit.stderr_tail));
    }
    if (!model.queue_paused) finishOrNext(model, fx);
    ensureInspecting(model, fx);
}

fn applyInspection(model: *Model, idx: usize, exit: native_sdk.EffectExit, fx: *Effects) void {
    const b = &model.books[idx];
    // The collected stdout holds log lines plus one inspection event; find it.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var found = false;
    var it = std.mem.splitScalar(u8, exit.output, '\n');
    while (it.next()) |ln| {
        const ev = events.parseLine(a, ln) orelse continue;
        if (ev == .inspection) {
            const ins = ev.inspection;
            b.total_chars = ins.total_chars;
            b.total_chunks = ins.total_chunks;
            b.chapter_count = ins.chapter_count;
            b.has_cover = ins.has_cover;
            b.cover_path.set(ins.cover_path);
            if (ins.cover_path.len > 0 and b.cover_image == 0) {
                b.cover_key = nextKey(model);
                fx.readFile(.{ .key = b.cover_key, .path = ins.cover_path, .on_result = Effects.fileMsg(.file_result) });
            }
            b.warning.set(ins.warning);
            b.section_overflow = ins.section_overflow;
            if (ins.section_overflow) b.warning.set("This book has more than 96 sections. Section selection is unavailable; the default content selection will be used.");
            b.section_count = ins.section_count;
            for (0..ins.section_count) |section_idx| {
                const section = ins.sections[section_idx];
                const dest = &b.sections[section_idx];
                dest.id.set(section.id);
                dest.title.set(section.title);
                dest.excerpt.set(section.excerpt);
                dest.word_count = section.word_count;
                dest.included = section.included;
            }
            b.sections_loaded = true;
            if (ins.title.len > 0) b.title.set(ins.title);
            if (ins.author.len > 0) b.author.set(ins.author);
            if (ins.resolved_backend.len > 0) b.resolved_backend.set(ins.resolved_backend);
            b.ckpt_exists = ins.ckpt_exists;
            b.resume_compatible = ins.ckpt_resume_compatible;
            b.ckpt_completed = ins.ckpt_completed;
            b.ckpt_total = ins.ckpt_total;
            if (ins.error_msg.len > 0) {
                b.err.set(ins.error_msg);
                b.status = .failed;
            } else if (b.preserve_complete) {
                b.status = .complete;
            } else if (ins.ckpt_exists and ins.ckpt_resume_compatible) {
                b.status = .resumable;
            } else {
                b.status = .ready;
            }
            b.preserve_complete = false;
            if (idx == model.selected) syncSelection(model);
            found = true;
            break;
        }
    }
    if (!found and b.status == .inspecting) {
        b.status = .failed;
        b.err.set(shortError(exit.stderr_tail));
    }
    // Duplicate-output blocking: an earlier book claiming the same path wins.
    for (0..idx) |j| {
        if (model.books[j].output.eql(b.output.slice()) and model.books[j].status != .blocked) {
            b.warning.set("Another book uses this output name. Both audiobook files will be kept.");
            break;
        }
    }
}

fn shortError(stderr_tail: []const u8) []const u8 {
    const t = std.mem.trim(u8, stderr_tail, " \t\r\n");
    if (t.len == 0) return "backend failed";
    // last non-empty line
    var last: []const u8 = t;
    var it = std.mem.splitScalar(u8, t, '\n');
    while (it.next()) |ln| {
        const l = std.mem.trim(u8, ln, " \t\r");
        if (l.len > 0) last = l;
    }
    return last;
}

// -------------------------------------------------------------- book intake

fn addFromText(model: *Model, text: []const u8) void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r\n\"'");
        if (line.len == 0) continue;
        addOne(model, line);
    }
}

fn addOne(model: *Model, path: []const u8) void {
    // Directories are handled asynchronously via `listDir`; here we only take
    // concrete .epub paths (the file picker and `ls` both yield those).
    if (std.ascii.endsWithIgnoreCase(path, ".epub")) addBook(model, path);
}

fn listDir(model: *Model, dir: []const u8, fx: *Effects) void {
    _ = model;
    if (dir.len == 0) return;
    var buf: [2200]u8 = undefined;
    var c = shell.Cmd.init(&buf);
    c.raw("ls -1 ");
    c.quoted(dir);
    c.raw("/*.epub 2>/dev/null");
    var argv = [_][]const u8{ "/bin/sh", "-c", c.slice() };
    fx.spawn(.{ .key = KEY_LSDIR, .argv = argv[0..], .output = .collect, .on_exit = Effects.exitMsg(.effect_exit) });
}

fn addBook(model: *Model, input: []const u8) void {
    if (model.book_count >= MAX_BOOKS) {
        model.notice.set("Library limit reached (24 books). Remove a book before adding more.");
        return;
    }
    // de-dup by input path
    for (0..model.book_count) |i| {
        if (model.books[i].input.eql(input)) return;
    }
    var b = Book{};
    b.id = model.next_book_id;
    model.next_book_id += 1;
    b.cfg = model.cfg;
    b.input.set(input);
    b.output.set(defaultOutputPath(model, input, model.cfg.format));
    b.status = .pending;
    model.books[model.book_count] = b;
    model.book_count += 1;
    model.selected = model.book_count - 1;
    syncSelection(model);
    if (model.screen != .library) model.screen = .library;
}

fn outputPath(input: []const u8, format: config.Format) []const u8 {
    // Static per-call buffer is fine: consumed immediately into Book.output.
    const S = struct {
        var buf: [1024]u8 = undefined;
    };
    var stem = input;
    if (std.ascii.endsWithIgnoreCase(input, ".epub")) stem = input[0 .. input.len - 5];
    return std.fmt.bufPrint(&S.buf, "{s}{s}", .{ stem, format.ext() }) catch input;
}

fn defaultOutputPath(model: *const Model, input: []const u8, format: config.Format) []const u8 {
    const S = struct {
        var buf: [1400]u8 = undefined;
    };
    const name = basename(input);
    const stem = if (name.len > 5) name[0 .. name.len - 5] else name;
    if (model.output_directory.len > 0) return std.fmt.bufPrint(&S.buf, "{s}/{s}{s}", .{ std.mem.trimEnd(u8, model.output_directory.slice(), "/"), stem, format.ext() }) catch outputPath(input, format);
    return std.fmt.bufPrint(&S.buf, "{s}/Music/Audiobook Maker/{s}{s}", .{ getenvSlice("HOME") orelse "/tmp", stem, format.ext() }) catch outputPath(input, format);
}
fn setFormat(model: *Model, f: config.Format, fx: *Effects) void {
    _ = fx;
    if (f == model.cfg.format) return;
    model.cfg.format = f;
    if (model.selected < model.book_count) {
        const book = &model.books[model.selected];
        const current = book.output.slice();
        var buf: [1100]u8 = undefined;
        const dot = std.mem.lastIndexOfScalar(u8, current, '.') orelse current.len;
        book.output.set(std.fmt.bufPrint(&buf, "{s}{s}", .{ current[0..dot], f.ext() }) catch return);
    }
}

fn syncSelection(model: *Model) void {
    if (model.selected >= model.book_count) return;
    const book = &model.books[model.selected];
    model.cfg = book.cfg;
    model.voice_index = config.voiceIndexById(book.cfg.voice);
    for (config.speeds, 0..) |speed, i| {
        if (speed == book.cfg.speed) model.speed_index = i;
    }
    model.title_buf.clear();
    model.title_buf.set(if (book.title_override.len > 0) book.title_override.slice() else book.title.slice());
    model.author_buf.clear();
    model.author_buf.set(if (book.author_override.len > 0) book.author_override.slice() else book.author.slice());
}
fn invalidateBook(model: *Model, idx: usize, fx: *Effects) void {
    const book = &model.books[idx];
    book.revision += 1;
    book.status = .pending;
    book.err.len = 0;
    book.preview_path.len = 0;
    book.preserve_complete = false;
    ensureInspecting(model, fx);
}
fn nextKey(model: *Model) u64 {
    model.next_effect_key += 1;
    return model.next_effect_key;
}
fn bookIndex(model: *const Model, id: u64) ?usize {
    for (0..model.book_count) |i| {
        if (model.books[i].id == id) return i;
    }
    return null;
}
fn bookForEffect(model: *const Model, key: u64) ?usize {
    for (0..model.book_count) |i| {
        const b = &model.books[i];
        if (b.inspect_key == key or b.convert_key == key or b.preview_key == key or b.cover_key == key or b.request_key == key) return i;
    }
    return null;
}

fn removeSelected(model: *Model, fx: *Effects) void {
    if (model.selected >= model.book_count or model.converting or model.previewing or model.inspect_in_flight) return;
    var i = model.selected;
    while (i + 1 < model.book_count) : (i += 1) {
        model.books[i] = model.books[i + 1];
    }
    model.book_count -= 1;
    if (model.selected >= model.book_count and model.book_count > 0) model.selected = model.book_count - 1;
    syncSelection(model);
    ensureInspecting(model, fx);
}

// ------------------------------------------------------------- effect spawns

// One boot script does everything the Zig side can't (fs walks are behind
// std.Io now): prefer the bundled Resources ($1) when packaged, else find the
// project root by walking up; pick the interpreter; read hw.memsize; run the
// Python preflight — emitting a single JSON line.
const DETECT_SCRIPT =
    "res=\"$1\"\n" ++
    "root=\"\"; py=\"\"\n" ++
    "if [ -n \"$res\" ] && [ -f \"$res/backend/app.py\" ]; then\n" ++
    "  root=\"$res/backend\"\n" ++
    "  [ -x \"$res/python/bin/python3\" ] && py=\"$res/python/bin/python3\"\n" ++
    "  export PATH=\"$res:$PATH\"\n" ++
    "fi\n" ++
    "if [ -z \"$root\" ]; then\n" ++
    "  d=\"${AUDIOBOOK_PROJECT_ROOT:-$PWD}\"\n" ++
    "  while [ -n \"$d\" ] && [ \"$d\" != \"/\" ]; do\n" ++
    "    if [ -f \"$d/app.py\" ] && [ -d \"$d/audiobook_backend\" ]; then root=\"$d\"; break; fi\n" ++
    "    d=$(dirname \"$d\")\n" ++
    "  done\n" ++
    "fi\n" ++
    "if [ -z \"$py\" ]; then\n" ++
    "  py=python3\n" ++
    "  if [ -n \"$AUDIOBOOK_PYTHON\" ] && [ -x \"$AUDIOBOOK_PYTHON\" ]; then py=\"$AUDIOBOOK_PYTHON\";\n" ++
    "  elif [ -n \"$PYTHON\" ] && [ -x \"$PYTHON\" ]; then py=\"$PYTHON\";\n" ++
    "  elif [ -n \"$root\" ] && [ -x \"$root/.venv/bin/python\" ]; then py=\"$root/.venv/bin/python\"; fi\n" ++
    "fi\n" ++
    "mem=$(sysctl -n hw.memsize 2>/dev/null || echo 0)\n" ++
    "\"$py\" - \"$root\" \"$py\" \"$mem\" \"$res\" <<'PY'\n" ++
    "import json,sys,shutil,importlib.util as u\n" ++
    "def s(m):\n" ++
    "  try: return u.find_spec(m) is not None\n" ++
    "  except Exception: return False\n" ++
    "root,py,mem,res=sys.argv[1],sys.argv[2],int(sys.argv[3] or 0),sys.argv[4]\n" ++
    "print(json.dumps({'root':root,'python':py,'mem':mem,'bundled':bool(res)," ++
    "'version':'%d.%d.%d'%sys.version_info[:3],'kokoro':s('kokoro'),'mlx':s('mlx_audio')," ++
    "'misaki':s('misaki'),'ffmpeg':shutil.which('ffmpeg') or ''}))\n" ++
    "PY\n";

fn startDetect(model: *Model, fx: *Effects) void {
    var argv = [_][]const u8{ "/bin/sh", "-c", DETECT_SCRIPT, "sh", model.res_dir.slice() };
    fx.spawn(.{
        .key = KEY_DETECT,
        .argv = argv[0..],
        .output = .collect,
        .on_exit = Effects.exitMsg(.effect_exit),
    });
}

fn applyDetect(model: *Model, output: []const u8, fx: *Effects) void {
    var py_ver: []const u8 = "";
    var kokoro = false;
    var mlx = false;
    var misaki = false;
    var bundled = false;
    var ffmpeg: []const u8 = "";
    var root: []const u8 = "";
    var python: []const u8 = "";
    var mem: u64 = 0;
    // Bundled paths are long absolute paths; the parsed JSON Value needs
    // headroom well beyond the raw bytes.
    var scratch: [32 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);

    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \t\r\n");
        if (t.len == 0 or t[0] != '{') continue;
        const parsed = std.json.parseFromSlice(std.json.Value, fba.allocator(), t, .{}) catch continue;
        if (parsed.value != .object) continue;
        const o = parsed.value.object;
        if (o.get("root")) |v| {
            if (v == .string) root = v.string;
        }
        if (o.get("python")) |v| {
            if (v == .string) python = v.string;
        }
        if (o.get("version")) |v| {
            if (v == .string) py_ver = v.string;
        }
        if (o.get("kokoro")) |v| {
            if (v == .bool) kokoro = v.bool;
        }
        if (o.get("mlx")) |v| {
            if (v == .bool) mlx = v.bool;
        }
        if (o.get("misaki")) |v| {
            if (v == .bool) misaki = v.bool;
        }
        if (o.get("bundled")) |v| {
            if (v == .bool) bundled = v.bool;
        }
        if (o.get("ffmpeg")) |v| {
            if (v == .string) ffmpeg = v.string;
        }
        if (o.get("mem")) |v| {
            if (v == .integer) mem = @intCast(@max(v.integer, 0));
        }
        break;
    }

    model.py_ok = root.len > 0;
    model.bundled = bundled;
    if (model.py_ok) {
        model.root.set(root);
        model.python.set(python);
        var app_buf: [1100]u8 = undefined;
        model.app_py.set(std.fmt.bufPrint(&app_buf, "{s}/app.py", .{root}) catch "");
    }
    model.low_mem = mem > 0 and mem <= 8 * 1024 * 1024 * 1024;
    if (model.low_mem and !bundled) model.cfg.use_mps = false;

    model.check_count = 0;
    addCheck(model, "Backend", model.py_ok, if (model.py_ok) "backend located" else "backend not found", if (bundled) "The app bundle looks incomplete — reinstall it" else "Run from the audiobook_maker project, or set AUDIOBOOK_PROJECT_ROOT");
    const py_ok = pythonVersionOk(py_ver);
    addCheck(model, "Python 3.10-3.12", py_ok, if (py_ok) py_ver else "Compatible Python not found", "./setup.sh");
    if (bundled) {
        const engine_ok = mlx and misaki;
        addCheck(model, "Voice engine (MLX)", engine_ok, if (engine_ok) "MLX ready" else "MLX runtime missing", "The app bundle looks incomplete — reinstall it");
    } else {
        addCheck(model, "Kokoro TTS", kokoro, if (kokoro) "installed" else "not installed", "pip install -r requirements.txt");
    }
    addCheck(model, "FFmpeg", ffmpeg.len > 0, if (ffmpeg.len > 0) "installed" else "not found on PATH", if (bundled) "The app bundle looks incomplete — reinstall it" else "brew install ffmpeg");

    var all_ok = true;
    for (0..model.check_count) |i| {
        if (!model.checks[i].ok) all_ok = false;
    }
    model.screen = if (all_ok) .library else .setup;
    // Runtime is known now — inspect any book pre-loaded via the open-with-file
    // seam (or added while detection was still running).
    if (model.screen == .library) stateCommand(model, KEY_LOAD, "load", null, fx);
}

fn pythonVersionOk(ver: []const u8) bool {
    // "3.11.9" — accept 3.10..3.12
    var it = std.mem.splitScalar(u8, ver, '.');
    const major = std.fmt.parseInt(u32, it.first(), 10) catch return false;
    const minor = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch return false;
    return major == 3 and minor >= 10 and minor <= 12;
}

fn addCheck(model: *Model, name: []const u8, ok: bool, message: []const u8, fix: []const u8) void {
    if (model.check_count >= MAX_CHECKS) return;
    var c = Check{};
    c.name.set(name);
    c.ok = ok;
    c.message.set(message);
    if (!ok) c.fix.set(fix);
    model.checks[model.check_count] = c;
    model.check_count += 1;
}

fn openPicker(model: *Model, fx: *Effects) void {
    _ = model;
    const script =
        "set out to \"\"\n" ++
        "try\n" ++
        "set fs to choose file with prompt \"Select EPUB files\" with multiple selections allowed\n" ++
        "repeat with f in fs\n" ++
        "set out to out & POSIX path of f & linefeed\n" ++
        "end repeat\n" ++
        "end try\n" ++
        "return out\n";
    var buf: [4096]u8 = undefined;
    var c = shell.Cmd.init(&buf);
    c.quoted("osascript");
    c.arg("-e");
    c.arg(script);
    var argv = [_][]const u8{ "/bin/sh", "-c", c.slice() };
    fx.spawn(.{
        .key = KEY_PANEL,
        .argv = argv[0..],
        .output = .collect,
        .on_exit = Effects.exitMsg(.effect_exit),
    });
}

fn ensureInspecting(model: *Model, fx: *Effects) void {
    if (model.inspect_in_flight or model.converting or model.previewing or !model.state_loaded) return;
    for (0..model.book_count) |i| {
        if (model.books[i].status == .pending) {
            model.books[i].status = .inspecting;
            model.books[i].inspect_revision = model.books[i].revision;
            spawnBackend(model, i, .inspect, fx);
            model.inspect_in_flight = true;
            return;
        }
    }
}

fn startNextConvert(model: *Model, fx: *Effects) void {
    if (model.queue_paused) return;
    for (0..model.book_count) |i| {
        const b = &model.books[i];
        if (model.queue_scope_id != 0 and b.id != model.queue_scope_id) continue;
        if (b.status == .ready or b.status == .resumable) {
            b.status = .converting;
            b.cur_chunk = 0;
            b.run_total_chunks = b.total_chunks;
            b.phase = .parsing;
            b.model_message.len = 0;
            b.chunk_ms = 0;
            b.estimated_chunk_ms = 0;
            b.timing_samples = 0;
            b.last_progress_ms = 0;
            model.active = i;
            model.selected = i;
            syncSelection(model);
            model.converting = true;
            spawnBackend(model, i, .convert, fx);
            return;
        }
    }
    // nothing left to run
    model.total_ms = native_sdk.monotonicMs() - model.started_ms;
    model.screen = .library;
    notifyDone(model, fx);
}

fn finishOrNext(model: *Model, fx: *Effects) void {
    if (model.converting) return;
    startNextConvert(model, fx);
}

/// Build and dispatch a backend spawn (inspect via .collect, convert via
/// streamed .lines) through `/bin/sh -c`.
fn spawnBackend(model: *Model, idx: usize, mode: config.RunMode, fx: *Effects) void {
    const book = &model.books[idx];
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var run_cfg = book.cfg;
    run_cfg.title = book.title_override.slice();
    run_cfg.author = book.author_override.slice();
    run_cfg.cover = book.cover_override.slice();
    if (model.bundled) run_cfg.backend = .mlx;
    if (mode == .preview) {
        run_cfg.format = .mp3;
        run_cfg.checkpoint_enabled = false;
    }
    if (mode == .convert and book.cfg.checkpoint_enabled and book.resume_compatible and book.resume_choice and book.ckpt_completed > 0) run_cfg.resume_requested = true;
    var args_buf: [80][]const u8 = undefined;
    const args = config.buildArgs(&args_buf, allocator, run_cfg, book.input.slice(), if (mode == .preview) previewOutput(model, book) else book.output.slice(), mode, "", apple_host.isAppleSilicon(), model.low_mem) catch return;
    var count = args.len;
    const directory = std.fmt.allocPrint(allocator, "{s}/books/{d}", .{ model.state_dir.slice(), book.id }) catch return;
    if (book.sections_loaded and !book.section_overflow) {
        args_buf[count] = "--sections_file";
        args_buf[count + 1] = std.fmt.allocPrint(allocator, "{s}/sections.json", .{directory}) catch return;
        count += 2;
    }
    if (mode == .inspect) {
        args_buf[count] = "--inspect_assets_dir";
        args_buf[count + 1] = std.fmt.allocPrint(allocator, "{s}/assets", .{directory}) catch return;
        count += 2;
    }
    if (mode == .convert and book.ckpt_exists and !book.resume_choice) {
        args_buf[count] = "--reset_checkpoint";
        count += 1;
    }
    var env = std.StringHashMap([]const u8).init(allocator);
    env.put("PYTHONUNBUFFERED", "1") catch return;
    if (model.bundled) {
        env.put("PATH", std.fmt.allocPrint(allocator, "{s}:{s}", .{ model.res_dir.slice(), getenvSlice("PATH") orelse "/usr/bin:/bin" }) catch return) catch return;
        env.put("DYLD_LIBRARY_PATH", model.res_dir.slice()) catch return;
    }
    if (run_cfg.backend != .mlx and run_cfg.backend != .mock) {
        env.put("OMP_NUM_THREADS", "4") catch return;
        env.put("OPENBLAS_NUM_THREADS", "2") catch return;
        if (run_cfg.use_mps) {
            env.put("PYTORCH_ENABLE_MPS_FALLBACK", "1") catch return;
            env.put("PYTORCH_MPS_HIGH_WATERMARK_RATIO", "0.0") catch return;
        }
    }
    // JSON object avoids the SDK's 2 KiB argv bound and preserves paths/Unicode exactly.
    const selection = std.json.parseFromSlice(std.json.Value, allocator, selectionJson(book, allocator) catch return, .{}) catch return;
    var env_object: std.json.ObjectMap = .{};
    var iterator = env.iterator();
    while (iterator.next()) |entry| {
        env_object.put(allocator, entry.key_ptr.*, .{ .string = entry.value_ptr.* }) catch return;
    }
    book.pending_mode = mode;
    book.prepared_attempt = nextKey(model);
    book.request_key = nextKey(model);
    const pid_file = std.fmt.allocPrint(allocator, "{s}/attempt-{d}.pid", .{ directory, book.prepared_attempt }) catch return;
    const request = std.json.Stringify.valueAlloc(allocator, .{ .pid_file = pid_file, .root = model.root.slice(), .script = model.app_py.slice(), .directory = directory, .args = args_buf[0..count], .selection = selection.value, .env = std.json.Value{ .object = env_object } }, .{}) catch return;
    if (mode == .convert) book.convert_key = book.prepared_attempt else if (mode == .preview) book.preview_key = book.prepared_attempt else {
        book.inspect_key = book.prepared_attempt;
        model.inspect_key = book.prepared_attempt;
    }
    fx.writeFile(.{ .key = book.request_key, .path = bookAssetPath(model, book, "request.json"), .bytes = request, .on_result = Effects.fileMsg(.file_result) });
}
fn requestStop(model: *Model, book: *const Book, fx: *Effects) void {
    if (book.request_key != 0) return; // the pending write callback will acknowledge cancellation
    var helper_buf: [1200]u8 = undefined;
    const helper = std.fmt.bufPrint(&helper_buf, "{s}/audiobook_backend/desktop_state.py", .{model.root.slice()}) catch return;
    var pid_buf: [1400]u8 = undefined;
    const pid_file = std.fmt.bufPrint(&pid_buf, "{s}/books/{d}/attempt-{d}.pid", .{ model.state_dir.slice(), book.id, book.prepared_attempt }) catch return;
    var argv = [_][]const u8{ model.python.slice(), helper, "stop", pid_file };
    fx.spawn(.{ .key = nextKey(model), .argv = &argv, .on_exit = Effects.exitMsg(.effect_exit) });
}
fn launchPrepared(model: *Model, idx: usize, fx: *Effects) void {
    const book = &model.books[idx];
    var helper_buf: [1200]u8 = undefined;
    const helper = std.fmt.bufPrint(&helper_buf, "{s}/audiobook_backend/desktop_state.py", .{model.root.slice()}) catch return;
    var argv = [_][]const u8{ model.python.slice(), helper, "run", bookAssetPath(model, book, "request.json") };
    if (book.pending_mode == .convert or book.pending_mode == .preview) fx.spawn(.{ .key = book.prepared_attempt, .argv = &argv, .output = .lines, .max_line_bytes = 64 * 1024, .on_line = Effects.lineMsg(.effect_line), .on_exit = Effects.exitMsg(.effect_exit) }) else fx.spawn(.{ .key = book.prepared_attempt, .argv = &argv, .output = .collect, .on_exit = Effects.exitMsg(.effect_exit) });
}

fn revealSelected(model: *Model, fx: *Effects) void {
    if (model.selected >= model.book_count) return;
    const b = &model.books[model.selected];
    var buf: [2048]u8 = undefined;
    var c = shell.Cmd.init(&buf);
    c.quoted("open");
    c.arg("-R");
    c.arg(b.output.slice());
    var argv = [_][]const u8{ "/bin/sh", "-c", c.slice() };
    fx.spawn(.{ .key = KEY_FIREFORGET, .argv = argv[0..], .on_exit = Effects.exitMsg(.effect_exit) });
}

fn notifyDone(model: *Model, fx: *Effects) void {
    _ = model;
    var buf: [1024]u8 = undefined;
    var c = shell.Cmd.init(&buf);
    c.quoted("osascript");
    c.arg("-e");
    c.arg("display notification \"Your audiobooks are ready\" with title \"Audiobook Maker\"");
    var argv = [_][]const u8{ "/bin/sh", "-c", c.slice() };
    fx.spawn(.{ .key = KEY_FIREFORGET, .argv = argv[0..], .on_exit = Effects.exitMsg(.effect_exit) });
}

// -------------------------------------------------------- desktop services
fn bookAssetPath(model: *const Model, book: *const Book, leaf: []const u8) []const u8 {
    const S = struct {
        var buf: [1400]u8 = undefined;
    };
    return std.fmt.bufPrint(&S.buf, "{s}/books/{d}/{s}", .{ model.state_dir.slice(), book.id, leaf }) catch "";
}
fn previewOutput(model: *const Model, book: *const Book) []const u8 {
    return bookAssetPath(model, book, "preview.mp3");
}
fn selectionJson(book: *const Book, allocator: std.mem.Allocator) ![]const u8 {
    if (!book.sections_loaded or book.section_overflow) return "null";
    var ids: [events.MAX_SECTIONS][]const u8 = undefined;
    var n: usize = 0;
    for (book.sections[0..book.section_count]) |*section| {
        if (section.included) {
            ids[n] = section.id.slice();
            n += 1;
        }
    }
    return std.json.Stringify.valueAlloc(allocator, ids[0..n], .{});
}
fn scriptEffect(key: u64, script: []const u8, fx: *Effects) void {
    var argv = [_][]const u8{ "/usr/bin/osascript", "-e", script };
    fx.spawn(.{ .key = key, .argv = &argv, .output = .collect, .on_exit = Effects.exitMsg(.effect_exit) });
}
fn pickVoice(model: *Model, fx: *Effects) void {
    if (!model.cfgEditable() or model.selected >= model.book_count) return;
    model.voice_picker_book = model.books[model.selected].id;
    scriptEffect(KEY_VOICE, "set choice to choose from list {\"Heart — Warm\", \"Bella — Confident\", \"Nicole — Friendly\", \"Sarah — Professional\", \"Sky — Energetic\", \"Adam — Calm\", \"Michael — Authoritative\", \"Emma — Elegant\", \"Isabella — Sophisticated\", \"George — Classic\", \"Lewis — Modern\"} with prompt \"Choose a narrator. Preview a passage before converting.\" default items {\"Heart — Warm\"}\nif choice is false then return \"\"\nreturn item 1 of choice", fx);
}
fn chooseDestination(model: *Model, fx: *Effects) void {
    if (!model.cfgEditable() or model.selected >= model.book_count) return;
    model.destination_book = model.books[model.selected].id;
    scriptEffect(KEY_DEST, "try\nreturn POSIX path of (choose folder with prompt \"Save this audiobook in…\")\non error message number code\nif code is -128 then return \"\"\nerror message number code\nend try", fx);
}
fn playAudio(model: *Model, preview: bool, fx: *Effects) void {
    if (model.playing) {
        fx.cancel(KEY_PLAYER);
        return;
    }
    const book = model.sel() orelse return;
    const path = if (preview and book.preview_path.len > 0) book.preview_path.slice() else if (!preview and book.status == .complete) book.output.slice() else return;
    var argv = [_][]const u8{ "/usr/bin/afplay", path };
    fx.spawn(.{ .key = KEY_PLAYER, .argv = &argv, .on_exit = Effects.exitMsg(.effect_exit) });
    model.playing = true;
}
fn onFile(model: *Model, result: native_sdk.EffectFileResult, fx: *Effects) void {
    if (result.key == KEY_SAVEFILE) {
        if (result.outcome == .ok) {
            var path: [1200]u8 = undefined;
            stateCommand(model, KEY_SAVE, "save_file", std.fmt.bufPrint(&path, "{s}/pending-library.json", .{model.state_dir.slice()}) catch return, fx);
        } else {
            model.saving = false;
            model.notice.set("Could not save the library. Check available disk space.");
        }
        return;
    }
    const idx = bookForEffect(model, result.key) orelse return;
    const book = &model.books[idx];
    if (result.key == book.request_key) {
        book.request_key = 0;
        if (result.outcome == .ok and !book.stop_requested) launchPrepared(model, idx, fx) else if (book.stop_requested) {
            onExit(model, .{ .key = book.prepared_attempt, .reason = .cancelled }, fx);
            saveLibrary(model, fx);
        } else {
            book.err.set("Cannot prepare this job. Check available disk space.");
            onExit(model, .{ .key = book.prepared_attempt, .reason = .spawn_failed }, fx);
        }
        return;
    }
    if (result.key == book.cover_key) {
        book.cover_key = 0;
        if (result.outcome == .ok) {
            _ = fx.registerImageBytes(book.id, result.bytes) catch return;
            book.cover_image = book.id;
        }
    }
}
fn stateCommand(model: *const Model, key: u64, action: []const u8, payload: ?[]const u8, fx: *Effects) void {
    var buf: [65536]u8 = undefined;
    var cmd = shell.Cmd.init(&buf);
    cmd.raw("cd ");
    cmd.quoted(model.root.slice());
    cmd.raw(" && ");
    cmd.quoted(model.python.slice());
    cmd.arg("-m");
    cmd.arg("audiobook_backend.desktop_state");
    cmd.arg(action);
    if (payload) |value| cmd.arg(value);
    if (cmd.overflow) return;
    var argv = [_][]const u8{ "/bin/sh", "-c", cmd.slice() };
    fx.spawn(.{ .key = key, .argv = &argv, .output = .collect, .on_exit = Effects.exitMsg(.effect_exit) });
}
const SavedBook = struct {
    id: u64,
    input: []const u8,
    output: []const u8,
    title: []const u8,
    author: []const u8,
    title_override: []const u8,
    author_override: []const u8,
    cover_override: []const u8,
    status: []const u8,
    voice: []const u8,
    speed: f32,
    format: []const u8,
    bitrate: []const u8,
    backend: []const u8,
    normalize: bool,
    checkpoint: bool,
    use_mps: bool,
    selected_sections: ?[]const []const u8,
};
fn saveLibrary(model: *Model, fx: *Effects) void {
    if (!model.state_loaded or model.state_readonly or model.root.len == 0) return;
    if (model.saving) {
        model.save_pending = true;
        return;
    }
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const books = a.alloc(SavedBook, model.book_count) catch return;
    for (books, 0..) |*saved, i| {
        const book = &model.books[i];
        var selected: ?[][]const u8 = null;
        if (book.sections_loaded and !book.section_overflow) {
            const ids = a.alloc([]const u8, book.section_count) catch return;
            var n: usize = 0;
            for (book.sections[0..book.section_count]) |*section| {
                if (section.included) {
                    ids[n] = section.id.slice();
                    n += 1;
                }
            }
            selected = ids[0..n];
        }
        saved.* = .{ .id = book.id, .input = book.input.slice(), .output = book.output.slice(), .title = book.title.slice(), .author = book.author.slice(), .title_override = book.title_override.slice(), .author_override = book.author_override.slice(), .cover_override = book.cover_override.slice(), .status = @tagName(book.status), .voice = book.cfg.voice, .speed = book.cfg.speed, .format = book.cfg.format.flag(), .bitrate = book.cfg.bitrate.flag(), .backend = book.cfg.backend.flag(), .normalize = book.cfg.normalize, .checkpoint = book.cfg.checkpoint_enabled, .use_mps = book.cfg.use_mps, .selected_sections = selected };
    }
    const payload = std.json.Stringify.valueAlloc(a, .{ .version = @as(u32, 1), .output_directory = model.output_directory.slice(), .books = books }, .{}) catch return;
    if (payload.len > 900000) {
        model.notice.set("Library settings are too large to save. Remove unused books.");
        return;
    }
    model.saving = true;
    var path_buf: [1200]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/pending-library.json", .{model.state_dir.slice()}) catch return;
    fx.writeFile(.{ .key = KEY_SAVEFILE, .path = path, .bytes = payload, .on_result = Effects.fileMsg(.file_result) });
}
fn valueString(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = obj.get(key) orelse return "";
    return if (v == .string) v.string else "";
}
fn valueInt(obj: std.json.ObjectMap, key: []const u8, default: u64) u64 {
    const v = obj.get(key) orelse return default;
    return if (v == .integer and v.integer >= 0) @intCast(v.integer) else default;
}
fn valueBool(obj: std.json.ObjectMap, key: []const u8, default: bool) bool {
    const v = obj.get(key) orelse return default;
    return if (v == .bool) v.bool else default;
}
fn restoreLibrary(model: *Model, output: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), output, .{}) catch {
        model.state_readonly = true;
        model.notice.set("Could not restore saved library. Existing saved data was kept; saving is disabled.");
        return;
    };
    if (parsed.value != .object) return;
    const obj = parsed.value.object;
    model.state_dir.set(valueString(obj, "state_dir"));
    model.output_directory.set(valueString(obj, "output_directory"));
    for (model.books[0..model.book_count]) |*preloaded| {
        preloaded.output.set(defaultOutputPath(model, preloaded.input.slice(), preloaded.cfg.format));
    }
    model.notice.set(valueString(obj, "warning"));
    model.state_readonly = !valueBool(obj, "save_allowed", true);
    const entries = obj.get("books") orelse return;
    if (entries != .array) return;
    for (entries.array.items) |entry| {
        if (entry != .object or model.book_count >= MAX_BOOKS) continue;
        const o = entry.object;
        const input = valueString(o, "input");
        if (input.len == 0) continue;
        var duplicate = false;
        for (model.books[0..model.book_count]) |*book| {
            if (book.input.eql(input)) duplicate = true;
        }
        if (duplicate) continue;
        const i = model.book_count;
        var book = &model.books[i];
        book.* = .{};
        book.id = valueInt(o, "id", model.next_book_id);
        for (model.books[0..model.book_count]) |*existing| {
            if (existing.id == book.id) {
                book.id = model.next_book_id;
                break;
            }
        }
        model.next_book_id = @max(model.next_book_id, book.id + 1);
        book.input.set(input);
        book.output.set(valueString(o, "output"));
        book.title.set(valueString(o, "title"));
        book.author.set(valueString(o, "author"));
        book.title_override.set(valueString(o, "title_override"));
        book.author_override.set(valueString(o, "author_override"));
        book.cover_override.set(valueString(o, "cover_override"));
        const vi = config.voiceIndexById(valueString(o, "voice"));
        book.cfg.voice = config.voices[vi].id;
        book.cfg.accent = config.voices[vi].accent;
        if (o.get("speed")) |speed| {
            book.cfg.speed = switch (speed) {
                .float => @floatCast(speed.float),
                .integer => @floatFromInt(speed.integer),
                else => 1.0,
            };
        }
        book.cfg.format = if (std.mem.eql(u8, valueString(o, "format"), "mp3")) .mp3 else .m4b;
        const bitrate = valueString(o, "bitrate");
        book.cfg.bitrate = if (std.mem.eql(u8, bitrate, "128k")) .k128 else if (std.mem.eql(u8, bitrate, "320k")) .k320 else .k192;
        book.cfg.backend = std.meta.stringToEnum(config.Backend, valueString(o, "backend")) orelse .auto;
        book.cfg.normalize = valueBool(o, "normalize", false);
        book.cfg.checkpoint_enabled = valueBool(o, "checkpoint", true);
        book.cfg.use_mps = valueBool(o, "use_mps", true);
        book.preserve_complete = std.mem.eql(u8, valueString(o, "status"), "complete") and valueBool(o, "output_exists", false);
        if (o.get("selected_sections")) |sections| {
            if (sections == .array and sections.array.items.len <= events.MAX_SECTIONS) {
                book.sections_loaded = true;
                for (sections.array.items) |id| {
                    if (id != .string) continue;
                    book.sections[book.section_count].id.set(id.string);
                    book.section_count += 1;
                }
            }
        }
        book.status = .pending;
        model.book_count += 1;
    }
    if (model.book_count > 0) {
        model.selected = 0;
        syncSelection(model);
    }
}

// -------------------------------------------------------------------- app

pub fn main(init: std.process.Init) !void {
    const app_state = try App.create(std.heap.page_allocator, .{
        .name = "audiobook-maker",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = boot,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
    });
    defer app_state.destroy();
    app_state.model = initialModel();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "audiobook-maker",
        .window_title = "Audiobook Maker",
        .bundle_id = "dev.native_sdk.audiobook_maker",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}

test "book settings are isolated and running settings stay immutable" {
    var model = initialModel();
    model.book_count = 2;
    model.books[0].id = 1;
    model.books[1].id = 2;
    model.books[0].status = .ready;
    model.books[1].status = .ready;
    var fx = Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    update(&model, .set_br128, &fx);
    try std.testing.expect(model.books[0].cfg.bitrate == .k128);
    try std.testing.expect(model.books[1].cfg.bitrate == .k192);
    model.converting = true;
    update(&model, .set_br320, &fx);
    try std.testing.expect(model.books[0].cfg.bitrate == .k128);
    try std.testing.expect(model.books[1].cfg.bitrate == .k192);
}

test "pause waits for exit acknowledgement and never advances queue" {
    var model = initialModel();
    model.book_count = 2;
    model.converting = true;
    model.books[0].id = 1;
    model.books[0].convert_key = 4001;
    model.books[0].status = .converting;
    model.books[1].id = 2;
    model.books[1].status = .ready;
    var fx = Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    const argv = [_][]const u8{"fake-backend"};
    fx.spawn(.{ .key = 4001, .argv = &argv });
    update(&model, .cancel_convert, &fx);
    try std.testing.expect(model.converting);
    try std.testing.expect(model.queue_paused);
    try std.testing.expectEqual(@as(u64, 0), model.books[1].convert_key);
    update(&model, .{ .effect_exit = .{ .key = 4001, .reason = .cancelled } }, &fx);
    try std.testing.expect(!model.converting);
    try std.testing.expect(model.queue_paused);
    try std.testing.expect(model.books[1].status == .ready);
    try std.testing.expectEqual(@as(u64, 0), model.books[1].convert_key);
}

test "obsolete attempt events are ignored and keys survive book compaction" {
    var model = initialModel();
    model.book_count = 2;
    model.books[1].id = 42;
    model.books[1].convert_key = 5001;
    model.books[0] = model.books[1];
    model.book_count = 1;
    onLine(&model, .{ .key = 4999, .line = "{\"type\":\"progress\",\"current_chunk\":9,\"total_chunks\":10}" });
    try std.testing.expectEqual(@as(u32, 0), model.books[0].cur_chunk);
    onLine(&model, .{ .key = 5001, .line = "{\"type\":\"progress\",\"current_chunk\":3,\"total_chunks\":10}" });
    try std.testing.expectEqual(@as(u32, 3), model.books[0].cur_chunk);
}

test "restored interrupted jobs remain pending and IDs never collide" {
    var model = initialModel();
    model.book_count = 1;
    model.next_book_id = 2;
    model.books[0].id = 1;
    model.books[0].input.set("/first.epub");
    restoreLibrary(&model, "{\"state_dir\":\"/tmp/test-library\",\"books\":[{\"id\":1,\"input\":\"/second.epub\",\"output\":\"/second.m4b\",\"status\":\"converting\"},{\"id\":7,\"input\":\"/third.epub\",\"output\":\"/missing.m4b\",\"status\":\"complete\",\"output_exists\":false}]}");
    try std.testing.expectEqual(@as(usize, 3), model.book_count);
    try std.testing.expect(model.books[0].id != model.books[1].id);
    try std.testing.expect(model.books[1].status == .pending);
    try std.testing.expect(!model.books[2].preserve_complete);
    try std.testing.expect(!model.converting);
}

test "selected conversion queues only the selected book and snapshots JSON" {
    var model = initialModel();
    model.state_loaded = true;
    model.book_count = 2;
    model.selected = 1;
    model.state_dir.set("/tmp/audiobook-test");
    model.root.set("/test");
    model.python.set("python3");
    model.app_py.set("/test/app.py");
    model.books[0].id = 1;
    model.books[1].id = 2;
    model.books[0].status = .ready;
    model.books[1].status = .ready;
    model.books[0].input.set("/one.epub");
    model.books[1].input.set("/two.epub");
    model.books[0].output.set("/one.m4b");
    model.books[1].output.set("/two.m4b");
    var fx = Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    update(&model, .convert_selected, &fx);
    try std.testing.expectEqual(@as(u64, 2), model.queue_scope_id);
    try std.testing.expect(model.books[0].status == .ready);
    try std.testing.expect(model.books[1].status == .converting);
    const request = fx.pendingFileAt(0) orelse return error.MissingRequest;
    try std.testing.expect(std.mem.indexOf(u8, request.bytes, "two.epub") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.bytes, "--checkpoint") != null);
}

test "ETA waits for measured narration and ignores reused checkpoint progress" {
    var book = Book{ .phase = .inference, .run_total_chunks = 100, .cur_chunk = 80, .last_progress_ms = 1000 };
    try std.testing.expect(remainingMs(&book, 1000) == null);
    recordTiming(&book, 1000);
    try std.testing.expect(remainingMs(&book, 1000) == null);
    recordTiming(&book, 1000);
    try std.testing.expectEqual(@as(?u64, 20000), remainingMs(&book, 1000));
}

test "ETA smooths speed changes and counts down without going negative" {
    var book = Book{ .phase = .inference, .run_total_chunks = 10, .cur_chunk = 2, .last_progress_ms = 5000 };
    recordTiming(&book, 1000);
    recordTiming(&book, 3000);
    try std.testing.expectEqual(@as(f64, 1500), book.estimated_chunk_ms);
    try std.testing.expectEqual(@as(?u64, 12000), remainingMs(&book, 5000));
    try std.testing.expectEqual(@as(?u64, 11500), remainingMs(&book, 5500));
    book.cur_chunk = 9;
    try std.testing.expectEqual(@as(?u64, 0), remainingMs(&book, 99999));
    recordTiming(&book, 0);
    try std.testing.expectEqual(@as(u32, 2), book.timing_samples);
}

test "ETA formats approximate minutes and distinguishes final export and pause" {
    const allocator = std.testing.allocator;
    var book = Book{ .phase = .inference, .run_total_chunks = 10, .cur_chunk = 2, .last_progress_ms = 1000 };
    recordTiming(&book, 10000);
    recordTiming(&book, 10000);
    const minutes = remainingLabel(&book, 1000, allocator);
    defer allocator.free(minutes);
    try std.testing.expectEqualStrings("About 2 min of narration left", minutes);
    book.phase = .exporting;
    try std.testing.expectEqualStrings("Finishing audiobook…", remainingLabel(&book, 1000, allocator));
    book.phase = .loading_model;
    try std.testing.expectEqualStrings("Estimating time remaining…", remainingLabel(&book, 1000, allocator));
    book.stop_requested = true;
    try std.testing.expectEqualStrings("Pausing…", remainingLabel(&book, 1000, allocator));
}
