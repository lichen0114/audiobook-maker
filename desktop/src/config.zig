//! Config model + `app.py` argv builder.
//!
//! This is the Zig port of the CLI's `TTSConfig` (cli/src/types/profile.ts)
//! and the argv assembled in `runTTSAttempt` (cli/src/utils/tts-runner.ts).
//! Everything here is pure and unit-tested: given a config + input/output +
//! run mode, it produces the exact flag list the Python backend expects.

const std = @import("std");

pub const Accent = enum {
    a, // American English
    b, // British English

    pub fn code(self: Accent) []const u8 {
        return switch (self) {
            .a => "a",
            .b => "b",
        };
    }
};

pub const Backend = enum {
    auto,
    pytorch,
    mlx,
    mock,

    pub fn flag(self: Backend) []const u8 {
        return @tagName(self);
    }
};

pub const Format = enum {
    mp3,
    m4b,

    pub fn flag(self: Format) []const u8 {
        return @tagName(self);
    }

    pub fn ext(self: Format) []const u8 {
        return switch (self) {
            .mp3 => ".mp3",
            .m4b => ".m4b",
        };
    }
};

pub const Bitrate = enum {
    k128,
    k192,
    k320,

    pub fn flag(self: Bitrate) []const u8 {
        return switch (self) {
            .k128 => "128k",
            .k192 => "192k",
            .k320 => "320k",
        };
    }
};

/// A run of `app.py`. Each maps to a distinct backend mode.
pub const RunMode = enum {
    convert, // full run: parse + TTS + export
    inspect, // --inspect_job (one JSON inspection event, then exit)
    extract_metadata, // --extract_metadata
    check_checkpoint, // --check_checkpoint
};

pub const Voice = struct {
    id: []const u8,
    label: []const u8,
    accent: Accent,
};

/// The Kokoro voices the CLI's ConfigPanel exposes (cli/src/components/ConfigPanel.tsx).
pub const voices = [_]Voice{
    .{ .id = "af_heart", .label = "Heart — Warm", .accent = .a },
    .{ .id = "af_bella", .label = "Bella — Confident", .accent = .a },
    .{ .id = "af_nicole", .label = "Nicole — Friendly", .accent = .a },
    .{ .id = "af_sarah", .label = "Sarah — Professional", .accent = .a },
    .{ .id = "af_sky", .label = "Sky — Energetic", .accent = .a },
    .{ .id = "am_adam", .label = "Adam — Calm", .accent = .a },
    .{ .id = "am_michael", .label = "Michael — Authoritative", .accent = .a },
    .{ .id = "bf_emma", .label = "Emma — Elegant", .accent = .b },
    .{ .id = "bf_isabella", .label = "Isabella — Sophisticated", .accent = .b },
    .{ .id = "bm_george", .label = "George — Classic", .accent = .b },
    .{ .id = "bm_lewis", .label = "Lewis — Modern", .accent = .b },
};

pub fn voiceIndexById(id: []const u8) usize {
    for (voices, 0..) |v, i| {
        if (std.mem.eql(u8, v.id, id)) return i;
    }
    return 0;
}

/// The reading-speed presets the ConfigPanel exposes.
pub const speeds = [_]f32{ 0.75, 0.9, 1.0, 1.1, 1.25, 1.5 };

/// Mirror of `TTSConfig`. Every field has a default so the Native SDK
/// `UiApp.create` contract (all Model fields defaultable) holds transitively.
pub const TtsConfig = struct {
    voice: []const u8 = "af_heart",
    speed: f32 = 1.0,
    accent: Accent = .a,
    chunk_chars: u32 = 0, // 0 => let the backend pick its per-backend default
    use_mps: bool = true,
    backend: Backend = .auto,
    format: Format = .mp3,
    bitrate: Bitrate = .k192,
    normalize: bool = false,
    checkpoint_enabled: bool = false,
    resume_requested: bool = false,
    // M4B metadata overrides (empty len => omit the flag)
    title: []const u8 = "",
    author: []const u8 = "",
    cover: []const u8 = "",

    /// The `--device` argument, mirroring resolvePythonDeviceArg + apple-host.
    pub fn deviceArg(self: TtsConfig, is_apple_silicon: bool, low_memory: bool) []const u8 {
        return switch (self.backend) {
            .mlx => "mlx",
            .mock => "cpu",
            .auto, .pytorch => blk: {
                if (!is_apple_silicon) break :blk "auto";
                if (low_memory) break :blk "cpu";
                break :blk if (self.use_mps) "mps" else "cpu";
            },
        };
    }
};

/// Bounded argv builder — no allocation, writes into a caller-owned buffer.
/// Returns the used slice. `script_args` are the tokens AFTER the python
/// interpreter + script path (those come from py_runtime).
pub fn buildArgs(
    buf: [][]const u8,
    scratch: std.mem.Allocator,
    cfg: TtsConfig,
    input: []const u8,
    output: []const u8,
    mode: RunMode,
    log_file: []const u8,
    is_apple_silicon: bool,
    low_memory: bool,
) ![][]const u8 {
    var n: usize = 0;
    const B = struct {
        fn push(list: [][]const u8, idx: *usize, item: []const u8) void {
            list[idx.*] = item;
            idx.* += 1;
        }
    };
    const push = B.push;

    push(buf, &n, "--input");
    push(buf, &n, input);
    push(buf, &n, "--output");
    push(buf, &n, output);

    switch (mode) {
        .extract_metadata => push(buf, &n, "--extract_metadata"),
        .check_checkpoint => push(buf, &n, "--check_checkpoint"),
        .inspect => push(buf, &n, "--inspect_job"),
        .convert => {},
    }

    // Read-only modes still take the generation flags so the backend resolves
    // the same chunking/estimates it will use for the real run.
    push(buf, &n, "--voice");
    push(buf, &n, cfg.voice);
    push(buf, &n, "--speed");
    push(buf, &n, try std.fmt.allocPrint(scratch, "{d}", .{cfg.speed}));
    push(buf, &n, "--lang_code");
    push(buf, &n, cfg.accent.code());
    if (cfg.chunk_chars > 0) {
        push(buf, &n, "--chunk_chars");
        push(buf, &n, try std.fmt.allocPrint(scratch, "{d}", .{cfg.chunk_chars}));
    }
    push(buf, &n, "--backend");
    push(buf, &n, cfg.backend.flag());
    push(buf, &n, "--device");
    push(buf, &n, cfg.deviceArg(is_apple_silicon, low_memory));
    push(buf, &n, "--format");
    push(buf, &n, cfg.format.flag());
    push(buf, &n, "--bitrate");
    push(buf, &n, cfg.bitrate.flag());

    if (cfg.normalize) push(buf, &n, "--normalize");

    if (cfg.format == .m4b) {
        if (cfg.title.len > 0) {
            push(buf, &n, "--title");
            push(buf, &n, cfg.title);
        }
        if (cfg.author.len > 0) {
            push(buf, &n, "--author");
            push(buf, &n, cfg.author);
        }
        if (cfg.cover.len > 0) {
            push(buf, &n, "--cover");
            push(buf, &n, cfg.cover);
        }
    }

    if (mode == .convert) {
        if (cfg.checkpoint_enabled) push(buf, &n, "--checkpoint");
        if (cfg.resume_requested) push(buf, &n, "--resume");
    }

    push(buf, &n, "--event_format");
    push(buf, &n, "json");
    if (log_file.len > 0 and mode == .convert) {
        push(buf, &n, "--log_file");
        push(buf, &n, log_file);
    }
    push(buf, &n, "--no_rich");

    return buf[0..n];
}

test "buildArgs: mp3 convert on apple silicon with mps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [64][]const u8 = undefined;
    const cfg = TtsConfig{ .voice = "af_bella", .speed = 1.25, .backend = .pytorch, .use_mps = true };
    const args = try buildArgs(&buf, arena.allocator(), cfg, "/b.epub", "/b.mp3", .convert, "/tmp/x.log", true, false);

    try std.testing.expect(hasPair(args, "--input", "/b.epub"));
    try std.testing.expect(hasPair(args, "--output", "/b.mp3"));
    try std.testing.expect(hasPair(args, "--voice", "af_bella"));
    try std.testing.expect(hasPair(args, "--speed", "1.25"));
    try std.testing.expect(hasPair(args, "--backend", "pytorch"));
    try std.testing.expect(hasPair(args, "--device", "mps"));
    try std.testing.expect(hasPair(args, "--format", "mp3"));
    try std.testing.expect(hasPair(args, "--bitrate", "192k"));
    try std.testing.expect(hasPair(args, "--event_format", "json"));
    try std.testing.expect(hasFlag(args, "--no_rich"));
    try std.testing.expect(!hasFlag(args, "--normalize"));
    try std.testing.expect(!hasFlag(args, "--checkpoint"));
}

test "buildArgs: m4b inspect omits log + checkpoint, keeps metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [64][]const u8 = undefined;
    const cfg = TtsConfig{
        .format = .m4b,
        .title = "My Title",
        .author = "An Author",
        .checkpoint_enabled = true,
        .backend = .mock,
    };
    const args = try buildArgs(&buf, arena.allocator(), cfg, "/b.epub", "/b.m4b", .inspect, "/tmp/x.log", true, false);

    try std.testing.expect(hasFlag(args, "--inspect_job"));
    try std.testing.expect(hasPair(args, "--title", "My Title"));
    try std.testing.expect(hasPair(args, "--author", "An Author"));
    try std.testing.expect(hasPair(args, "--device", "cpu")); // mock => cpu
    try std.testing.expect(!hasFlag(args, "--checkpoint")); // inspect never checkpoints
    try std.testing.expect(!hasFlag(args, "--log_file")); // log only on convert
}

fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, flag)) return true;
    }
    return false;
}

fn hasPair(args: []const []const u8, flag: []const u8, value: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag) and std.mem.eql(u8, args[i + 1], value)) return true;
    }
    return false;
}
