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
const CONVERT_BASE: u64 = 2000;

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
};

pub const Check = struct {
    name: Str(24) = .{},
    ok: bool = false,
    message: Str(96) = .{},
    fix: Str(96) = .{},
};

pub const Book = struct {
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
    ckpt_completed: u32 = 0,
    ckpt_total: u32 = 0,
    resume_choice: bool = true,
    status: Status = .pending,
    // live conversion state
    phase: events.Phase = .parsing,
    cur_chunk: u32 = 0,
    run_total_chunks: u32 = 0,
    chunk_ms: u32 = 0,
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
    python: Str(1024) = .{},
    app_py: Str(1024) = .{},
    root: Str(1024) = .{},

    pub const view_unbound = .{
        "python",      "py_ok",      "low_mem",     "app_py",
        "root",        "started_ms", "active",      "total_ms",
        "inspect_in_flight",         "check_count", "book_count",
        "voice_index", "speed_index", "checks",     "books",
        "cfg",         "path_buf",   "screen",      "selected",
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
            };
        }
        return out;
    }

    pub fn statusText(self: *const Model, arena: std.mem.Allocator) []const u8 {
        if (self.converting) {
            const b = &self.books[self.active];
            return std.fmt.allocPrint(arena, "Converting {s} — {s} · {d}%", .{
                b.displayTitle(), b.phase.label(), pctInt(b),
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
        if (self.book_count == 0) return "Drop or add EPUB files to begin";
        return std.fmt.allocPrint(arena, "{d} book(s) · {d} ready · {d} resumable", .{
            self.book_count, ready, resumable,
        }) catch "";
    }

    pub fn canConvert(self: *const Model) bool {
        if (self.converting) return false;
        for (0..self.book_count) |i| {
            switch (self.books[i].status) {
                .ready, .resumable => return true,
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
        return std.fmt.allocPrint(arena, "{d} chapters · {s} chars · {d} chunks", .{
            b.chapter_count, thousands(arena, b.total_chars), b.total_chunks,
        }) catch "";
    }
    pub fn selStatus(self: *const Model, arena: std.mem.Allocator) []const u8 {
        const b = self.sel() orelse return "";
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
        return std.fmt.allocPrint(arena, "Checkpoint found: {d}/{d} chunks already generated.", .{
            b.ckpt_completed, b.ckpt_total,
        }) catch "";
    }
    pub fn selConverting(self: *const Model) bool {
        return if (self.sel()) |b| (b.status == .converting) else false;
    }
    pub fn selPct(self: *const Model) f32 {
        return if (self.sel()) |b| pct(b) else 0;
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

    // ---- done screen ----
    pub fn doneSummary(self: *const Model, arena: std.mem.Allocator) []const u8 {
        var complete: usize = 0;
        var failed: usize = 0;
        for (0..self.book_count) |i| {
            switch (self.books[i].status) {
                .complete => complete += 1,
                .failed, .skipped, .blocked => failed += 1,
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

fn statusLine(b: *const Book, arena: std.mem.Allocator) []const u8 {
    return switch (b.status) {
        .pending, .inspecting => "Inspecting…",
        .ready => std.fmt.allocPrint(arena, "Ready · {d} chunks", .{b.total_chunks}) catch "Ready",
        .resumable => std.fmt.allocPrint(arena, "Resumable · {d}/{d}", .{ b.ckpt_completed, b.ckpt_total }) catch "Resumable",
        .blocked => "Blocked · duplicate output",
        .converting => std.fmt.allocPrint(arena, "{s} · {d}%", .{ b.phase.label(), pctInt(b) }) catch "Converting",
        .complete => "Done",
        .failed => std.fmt.allocPrint(arena, "Failed: {s}", .{b.err.slice()}) catch "Failed",
        .skipped => "Skipped",
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
    cancel_convert,
    reveal_output,
    new_batch,

    // dispatched by the runtime effects channel, not the view
    pub const view_unbound = .{ "effect_line", "effect_exit" };
};

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

const App = native_sdk.UiApp(Model, Msg);
const Effects = App.Effects;

// --------------------------------------------------------------- lifecycle

pub fn initialModel() Model {
    return .{};
}

fn boot(model: *Model, fx: *Effects) void {
    model.cfg.use_mps = apple_host.defaultUseMps();
    model.screen = .checking;
    startDetect(model, fx);
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .effect_line => |line| onLine(model, line),
        .effect_exit => |exit| onExit(model, exit, fx),

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
            if (i < model.book_count) model.selected = i;
        },
        .remove_selected => removeSelected(model, fx),

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
                model.started_ms = native_sdk.monotonicMs();
                startNextConvert(model, fx);
            }
        },
        .cancel_convert => {
            if (model.converting) {
                fx.cancel(CONVERT_BASE + model.active);
                model.books[model.active].status = .failed;
                model.books[model.active].err.set("Cancelled");
                model.converting = false;
                finishOrNext(model, fx);
            }
        },
        .reveal_output => revealSelected(model, fx),
        .new_batch => {
            model.book_count = 0;
            model.selected = 0;
            model.converting = false;
            model.screen = .library;
        },
    }
}

// ---------------------------------------------------------- effect handlers

fn onLine(model: *Model, line: native_sdk.EffectLine) void {
    if (line.key < CONVERT_BASE) return;
    const idx = line.key - CONVERT_BASE;
    if (idx >= model.book_count) return;
    const b = &model.books[idx];

    var scratch: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const ev = events.parseLine(fba.allocator(), line.line) orelse return;
    switch (ev) {
        .phase => |p| b.phase = p,
        .progress => |pr| {
            b.cur_chunk = pr.current;
            b.run_total_chunks = pr.total;
        },
        .timing => |ms| b.chunk_ms = ms,
        .err => |m| b.err.set(m),
        else => {},
    }
}

fn onExit(model: *Model, exit: native_sdk.EffectExit, fx: *Effects) void {
    if (exit.key == KEY_DETECT) {
        applyDetect(model, exit.output);
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

    if (exit.key >= CONVERT_BASE) {
        const idx = exit.key - CONVERT_BASE;
        if (idx >= model.book_count) return;
        const b = &model.books[idx];
        model.converting = false;
        if (exit.reason == .exited and exit.code == 0) {
            b.status = .complete;
            b.cur_chunk = b.run_total_chunks;
        } else if (b.status != .failed) {
            b.status = .failed;
            if (b.err.len == 0) b.err.set(shortError(exit.stderr_tail));
        }
        finishOrNext(model, fx);
        return;
    }

    if (exit.key >= INSPECT_BASE) {
        const idx = exit.key - INSPECT_BASE;
        model.inspect_in_flight = false;
        if (idx < model.book_count) applyInspection(model, idx, exit);
        ensureInspecting(model, fx);
        return;
    }
}

fn applyInspection(model: *Model, idx: usize, exit: native_sdk.EffectExit) void {
    const b = &model.books[idx];
    // The collected stdout holds log lines plus one inspection event; find it.
    var scratch: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const a = fba.allocator();

    var found = false;
    var it = std.mem.splitScalar(u8, exit.output, '\n');
    while (it.next()) |ln| {
        fba.reset();
        const ev = events.parseLine(a, ln) orelse continue;
        if (ev == .inspection) {
            const ins = ev.inspection;
            b.total_chars = ins.total_chars;
            b.total_chunks = ins.total_chunks;
            b.chapter_count = ins.chapter_count;
            b.has_cover = ins.has_cover;
            if (ins.title.len > 0) b.title.set(ins.title);
            if (ins.author.len > 0) b.author.set(ins.author);
            if (ins.resolved_backend.len > 0) b.resolved_backend.set(ins.resolved_backend);
            b.ckpt_exists = ins.ckpt_exists;
            b.ckpt_completed = ins.ckpt_completed;
            b.ckpt_total = ins.ckpt_total;
            if (ins.error_msg.len > 0) {
                b.err.set(ins.error_msg);
                b.status = .failed;
            } else if (ins.ckpt_exists and ins.ckpt_resume_compatible) {
                b.status = .resumable;
            } else {
                b.status = .ready;
            }
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
            b.status = .blocked;
            b.err.set("Duplicate output path");
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
    if (model.book_count >= MAX_BOOKS) return;
    // de-dup by input path
    for (0..model.book_count) |i| {
        if (model.books[i].input.eql(input)) return;
    }
    var b = Book{};
    b.input.set(input);
    b.output.set(outputPath(input, model.cfg.format));
    b.status = .pending;
    model.books[model.book_count] = b;
    model.book_count += 1;
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

fn setFormat(model: *Model, f: config.Format, fx: *Effects) void {
    if (f == model.cfg.format) return;
    model.cfg.format = f;
    reinspectAll(model, fx);
}

fn reinspectAll(model: *Model, fx: *Effects) void {
    for (0..model.book_count) |i| {
        const b = &model.books[i];
        b.output.set(outputPath(b.input.slice(), model.cfg.format));
        if (b.status != .converting and b.status != .complete) {
            b.status = .pending;
            b.err.len = 0;
        }
    }
    ensureInspecting(model, fx);
}

fn removeSelected(model: *Model, fx: *Effects) void {
    if (model.selected >= model.book_count) return;
    if (model.books[model.selected].status == .converting) return;
    var i = model.selected;
    while (i + 1 < model.book_count) : (i += 1) {
        model.books[i] = model.books[i + 1];
    }
    model.book_count -= 1;
    if (model.selected >= model.book_count and model.book_count > 0) model.selected = model.book_count - 1;
    ensureInspecting(model, fx);
}

// ------------------------------------------------------------- effect spawns

// One boot script does everything the Zig side can't (fs walks are behind
// std.Io now): find the project root, pick the interpreter, read hw.memsize,
// and run the Python preflight — emitting a single JSON line.
const DETECT_SCRIPT =
    "d=\"${AUDIOBOOK_PROJECT_ROOT:-$PWD}\"\n" ++
    "root=\"\"\n" ++
    "while [ -n \"$d\" ] && [ \"$d\" != \"/\" ]; do\n" ++
    "  if [ -f \"$d/app.py\" ] && [ -d \"$d/audiobook_backend\" ]; then root=\"$d\"; break; fi\n" ++
    "  d=$(dirname \"$d\")\n" ++
    "done\n" ++
    "py=python3\n" ++
    "if [ -n \"$AUDIOBOOK_PYTHON\" ] && [ -x \"$AUDIOBOOK_PYTHON\" ]; then py=\"$AUDIOBOOK_PYTHON\";\n" ++
    "elif [ -n \"$PYTHON\" ] && [ -x \"$PYTHON\" ]; then py=\"$PYTHON\";\n" ++
    "elif [ -n \"$root\" ] && [ -x \"$root/.venv/bin/python\" ]; then py=\"$root/.venv/bin/python\"; fi\n" ++
    "mem=$(sysctl -n hw.memsize 2>/dev/null || echo 0)\n" ++
    "\"$py\" - \"$root\" \"$py\" \"$mem\" <<'PY'\n" ++
    "import json,sys,shutil,importlib.util as u\n" ++
    "def s(m):\n" ++
    "  try: return u.find_spec(m) is not None\n" ++
    "  except Exception: return False\n" ++
    "print(json.dumps({'root':sys.argv[1],'python':sys.argv[2],'mem':int(sys.argv[3] or 0)," ++
    "'version':'%d.%d.%d'%sys.version_info[:3],'kokoro':s('kokoro'),'mlx':s('mlx_audio')," ++
    "'ffmpeg':shutil.which('ffmpeg') or ''}))\n" ++
    "PY\n";

fn startDetect(model: *Model, fx: *Effects) void {
    _ = model;
    var argv = [_][]const u8{ "/bin/sh", "-c", DETECT_SCRIPT };
    fx.spawn(.{
        .key = KEY_DETECT,
        .argv = argv[0..],
        .output = .collect,
        .on_exit = Effects.exitMsg(.effect_exit),
    });
}

fn applyDetect(model: *Model, output: []const u8) void {
    var py_ver: []const u8 = "";
    var kokoro = false;
    var ffmpeg: []const u8 = "";
    var root: []const u8 = "";
    var python: []const u8 = "";
    var mem: u64 = 0;
    var scratch: [4096]u8 = undefined;
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
        if (o.get("ffmpeg")) |v| {
            if (v == .string) ffmpeg = v.string;
        }
        if (o.get("mem")) |v| {
            if (v == .integer) mem = @intCast(@max(v.integer, 0));
        }
        break;
    }

    model.py_ok = root.len > 0;
    if (model.py_ok) {
        model.root.set(root);
        model.python.set(python);
        var app_buf: [1100]u8 = undefined;
        model.app_py.set(std.fmt.bufPrint(&app_buf, "{s}/app.py", .{root}) catch "");
    }
    model.low_mem = mem > 0 and mem <= 8 * 1024 * 1024 * 1024;
    if (model.low_mem) model.cfg.use_mps = false;

    model.check_count = 0;
    addCheck(model, "Backend script", model.py_ok, if (model.py_ok) "app.py located" else "app.py not found near this app", "Run from the audiobook_maker project, or set AUDIOBOOK_PROJECT_ROOT");
    const py_ok = pythonVersionOk(py_ver);
    addCheck(model, "Python 3.10-3.12", py_ok, if (py_ok) py_ver else "Compatible Python not found", "./setup.sh");
    addCheck(model, "Kokoro TTS", kokoro, if (kokoro) "installed" else "not installed", "pip install -r requirements.txt");
    addCheck(model, "FFmpeg", ffmpeg.len > 0, if (ffmpeg.len > 0) "installed" else "not found on PATH", "brew install ffmpeg");

    var all_ok = true;
    for (0..model.check_count) |i| {
        if (!model.checks[i].ok) all_ok = false;
    }
    model.screen = if (all_ok) .library else .setup;
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
    if (model.inspect_in_flight or model.converting) return;
    for (0..model.book_count) |i| {
        if (model.books[i].status == .pending) {
            model.books[i].status = .inspecting;
            spawnBackend(model, i, .inspect, fx);
            model.inspect_in_flight = true;
            return;
        }
    }
}

fn startNextConvert(model: *Model, fx: *Effects) void {
    for (0..model.book_count) |i| {
        const b = &model.books[i];
        if (b.status == .ready or b.status == .resumable) {
            // start-fresh: drop an unwanted checkpoint before running
            if (b.ckpt_exists and !(b.status == .resumable and b.resume_choice)) {
                deleteCheckpoint(b.output.slice(), fx);
                b.ckpt_exists = false;
            }
            b.status = .converting;
            b.cur_chunk = 0;
            b.run_total_chunks = b.total_chunks;
            b.phase = .parsing;
            model.active = i;
            model.selected = i;
            model.converting = true;
            spawnBackend(model, i, .convert, fx);
            return;
        }
    }
    // nothing left to run
    model.total_ms = native_sdk.monotonicMs() - model.started_ms;
    model.screen = .done;
    notifyDone(model, fx);
}

fn finishOrNext(model: *Model, fx: *Effects) void {
    if (model.converting) return;
    startNextConvert(model, fx);
}

/// Build and dispatch a backend spawn (inspect via .collect, convert via
/// streamed .lines) through `/bin/sh -c`.
fn spawnBackend(model: *Model, idx: usize, mode: config.RunMode, fx: *Effects) void {
    const b = &model.books[idx];
    var arg_scratch: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arg_scratch);

    var run_cfg = model.cfg;
    if (mode == .convert and b.status == .converting) {
        if (b.resume_choice and b.ckpt_completed > 0) run_cfg.resume_requested = true;
    }

    var sargs_buf: [64][]const u8 = undefined;
    const sargs = config.buildArgs(
        &sargs_buf,
        fba.allocator(),
        run_cfg,
        b.input.slice(),
        b.output.slice(),
        mode,
        "",
        apple_host.isAppleSilicon(),
        model.low_mem,
    ) catch return;

    var cmd_buf: [16384]u8 = undefined;
    var c = shell.Cmd.init(&cmd_buf);
    if (model.root.len > 0) {
        c.raw("cd ");
        c.quoted(model.root.slice());
        c.raw("; ");
    }
    c.raw("PYTHONUNBUFFERED=1 ");
    if (run_cfg.backend != .mlx and run_cfg.backend != .mock) {
        c.raw("OMP_NUM_THREADS=4 OPENBLAS_NUM_THREADS=2 ");
        if (run_cfg.use_mps and apple_host.isAppleSilicon()) {
            c.raw("PYTORCH_ENABLE_MPS_FALLBACK=1 PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0 ");
        }
    }
    c.quoted(if (model.py_ok) model.python.slice() else "python3");
    c.arg(model.app_py.slice());
    for (sargs) |s| c.arg(s);

    var argv = [_][]const u8{ "/bin/sh", "-c", c.slice() };
    if (mode == .convert) {
        fx.spawn(.{
            .key = CONVERT_BASE + idx,
            .argv = argv[0..],
            .output = .lines,
            .max_line_bytes = 64 * 1024,
            .on_line = Effects.lineMsg(.effect_line),
            .on_exit = Effects.exitMsg(.effect_exit),
        });
    } else {
        fx.spawn(.{
            .key = INSPECT_BASE + idx,
            .argv = argv[0..],
            .output = .collect,
            .on_exit = Effects.exitMsg(.effect_exit),
        });
    }
}

fn deleteCheckpoint(output: []const u8, fx: *Effects) void {
    var path_buf: [1200]u8 = undefined;
    const dir = std.fmt.bufPrint(&path_buf, "{s}.checkpoint", .{output}) catch return;
    var buf: [2600]u8 = undefined;
    var c = shell.Cmd.init(&buf);
    c.raw("rm -rf ");
    c.quoted(dir);
    var argv = [_][]const u8{ "/bin/sh", "-c", c.slice() };
    fx.spawn(.{ .key = KEY_FIREFORGET, .argv = argv[0..], .on_exit = Effects.exitMsg(.effect_exit) });
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
