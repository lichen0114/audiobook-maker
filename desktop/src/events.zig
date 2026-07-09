//! Backend event parser — the Zig port of `parseOutputLine` +
//! `ProgressInfo` (cli/src/utils/tts-runner.ts) and the inspection payload
//! decode in cli/src/utils/batch-planner.ts.
//!
//! Every line the Python backend writes to stdout is one JSON event with a
//! `type` discriminator (JSON-first, with a small legacy-text fallback the
//! way the CLI keeps one). `parseLine` turns it into a typed `Event`.
//!
//! Returned string slices borrow from the input `line`, which the Native SDK
//! effects channel guarantees is alive for the whole `update` call — the
//! Model copies what it keeps into its own fixed buffers before returning.

const std = @import("std");
const config = @import("config.zig");

pub const Phase = enum {
    parsing,
    inference,
    concatenating,
    exporting,
    done,

    pub fn fromStr(s: []const u8) ?Phase {
        if (std.ascii.eqlIgnoreCase(s, "PARSING")) return .parsing;
        if (std.ascii.eqlIgnoreCase(s, "INFERENCE")) return .inference;
        if (std.ascii.eqlIgnoreCase(s, "CONCATENATING")) return .concatenating;
        if (std.ascii.eqlIgnoreCase(s, "EXPORTING")) return .exporting;
        if (std.ascii.eqlIgnoreCase(s, "DONE")) return .done;
        return null;
    }

    pub fn label(self: Phase) []const u8 {
        return switch (self) {
            .parsing => "Parsing",
            .inference => "Generating speech",
            .concatenating => "Concatenating",
            .exporting => "Exporting",
            .done => "Done",
        };
    }
};

pub const WorkerStatus = enum { idle, infer, encode };

pub const Inspection = struct {
    total_chars: u64 = 0,
    total_chunks: u32 = 0,
    chapter_count: u32 = 0,
    resolved_backend: []const u8 = "",
    title: []const u8 = "",
    author: []const u8 = "",
    has_cover: bool = false,
    ckpt_exists: bool = false,
    ckpt_resume_compatible: bool = false,
    ckpt_completed: u32 = 0,
    ckpt_total: u32 = 0,
    ckpt_reason: []const u8 = "",
    warning: []const u8 = "",
    error_msg: []const u8 = "",
};

pub const Event = union(enum) {
    phase: Phase,
    backend_resolved: config.Backend,
    total_chars: u64,
    chapter_count: u32,
    parse_progress: struct { current: u32, total: u32, chapters: u32 },
    progress: struct { current: u32, total: u32 },
    timing: u32, // per-chunk ms
    heartbeat: i64,
    worker: struct { id: u32, status: WorkerStatus, details: []const u8 },
    checkpoint: struct { code: []const u8, detail: []const u8 },
    log: struct { level: []const u8, message: []const u8 },
    err: []const u8,
    done: void,
    // --extract_metadata mode
    meta_title: []const u8,
    meta_author: []const u8,
    meta_has_cover: bool,
    meta_cover_path: []const u8,
    inspection: Inspection,
};

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn getNum(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        .string => |s| std.ascii.eqlIgnoreCase(s, "true"),
        else => null,
    };
}

/// Parse one stdout line. `arena` backs the transient JSON document; returned
/// slices are valid until the arena is reset (i.e. the whole update call).
pub fn parseLine(arena: std.mem.Allocator, line: []const u8) ?Event {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') {
        const parsed = std.json.parseFromSlice(std.json.Value, arena, trimmed, .{}) catch return legacy(trimmed);
        if (parsed.value != .object) return null;
        return parseJson(parsed.value.object) orelse legacy(trimmed);
    }
    return legacy(trimmed);
}

fn parseJson(obj: std.json.ObjectMap) ?Event {
    const t = getStr(obj, "type") orelse return null;

    if (std.mem.eql(u8, t, "phase")) {
        const p = getStr(obj, "phase") orelse return null;
        return .{ .phase = Phase.fromStr(p) orelse return null };
    }
    if (std.mem.eql(u8, t, "metadata")) {
        const key = getStr(obj, "key") orelse return null;
        if (std.mem.eql(u8, key, "backend_resolved")) {
            const val = getStr(obj, "value") orelse return null;
            return .{ .backend_resolved = std.meta.stringToEnum(config.Backend, val) orelse return null };
        }
        if (std.mem.eql(u8, key, "total_chars")) return .{ .total_chars = @intCast(getNum(obj, "value") orelse return null) };
        if (std.mem.eql(u8, key, "chapter_count")) return .{ .chapter_count = @intCast(getNum(obj, "value") orelse return null) };
        if (std.mem.eql(u8, key, "title")) return .{ .meta_title = getStr(obj, "value") orelse "" };
        if (std.mem.eql(u8, key, "author")) return .{ .meta_author = getStr(obj, "value") orelse "" };
        if (std.mem.eql(u8, key, "has_cover")) return .{ .meta_has_cover = (getBool(obj, "value") orelse false) };
        if (std.mem.eql(u8, key, "cover_path")) return .{ .meta_cover_path = getStr(obj, "value") orelse "" };
        return null;
    }
    if (std.mem.eql(u8, t, "parse_progress")) {
        const total: u32 = @intCast(getNum(obj, "total_items") orelse return null);
        if (total == 0) return null;
        return .{ .parse_progress = .{
            .current = @intCast(getNum(obj, "current_item") orelse 0),
            .total = total,
            .chapters = @intCast(getNum(obj, "current_chapter_count") orelse 0),
        } };
    }
    if (std.mem.eql(u8, t, "progress")) {
        const total: u32 = @intCast(getNum(obj, "total_chunks") orelse return null);
        if (total == 0) return null;
        return .{ .progress = .{
            .current = @intCast(getNum(obj, "current_chunk") orelse 0),
            .total = total,
        } };
    }
    if (std.mem.eql(u8, t, "timing")) return .{ .timing = @intCast(getNum(obj, "chunk_timing_ms") orelse return null) };
    if (std.mem.eql(u8, t, "heartbeat")) return .{ .heartbeat = getNum(obj, "heartbeat_ts") orelse return null };
    if (std.mem.eql(u8, t, "worker")) {
        const status_str = getStr(obj, "status") orelse return null;
        const status: WorkerStatus = if (std.mem.eql(u8, status_str, "INFER"))
            .infer
        else if (std.mem.eql(u8, status_str, "ENCODE"))
            .encode
        else
            .idle;
        return .{ .worker = .{
            .id = @intCast(getNum(obj, "id") orelse 0),
            .status = status,
            .details = getStr(obj, "details") orelse "",
        } };
    }
    if (std.mem.eql(u8, t, "checkpoint")) return .{ .checkpoint = .{
        .code = getStr(obj, "code") orelse "",
        .detail = getStr(obj, "detail") orelse "",
    } };
    if (std.mem.eql(u8, t, "log")) return .{ .log = .{
        .level = getStr(obj, "level") orelse "info",
        .message = getStr(obj, "message") orelse "",
    } };
    if (std.mem.eql(u8, t, "error")) return .{ .err = getStr(obj, "message") orelse "unknown error" };
    if (std.mem.eql(u8, t, "done")) return .done;
    if (std.mem.eql(u8, t, "inspection")) {
        const res = obj.get("result") orelse return null;
        if (res != .object) return null;
        return .{ .inspection = parseInspection(res.object) };
    }
    return null;
}

fn parseInspection(r: std.json.ObjectMap) Inspection {
    var ins = Inspection{};
    if (getNum(r, "total_chars")) |v| ins.total_chars = @intCast(v);
    if (getNum(r, "total_chunks")) |v| ins.total_chunks = @intCast(v);
    if (getNum(r, "chapter_count")) |v| ins.chapter_count = @intCast(v);
    if (getStr(r, "resolved_backend")) |v| ins.resolved_backend = v;

    if (r.get("epub_metadata")) |m| {
        if (m == .object) {
            if (getStr(m.object, "title")) |v| ins.title = v;
            if (getStr(m.object, "author")) |v| ins.author = v;
            if (getBool(m.object, "has_cover")) |v| ins.has_cover = v;
        }
    }
    if (r.get("checkpoint")) |c| {
        if (c == .object) {
            if (getBool(c.object, "exists")) |v| ins.ckpt_exists = v;
            if (getBool(c.object, "resume_compatible")) |v| ins.ckpt_resume_compatible = v;
            if (getNum(c.object, "completed_chunks")) |v| ins.ckpt_completed = @intCast(v);
            if (getNum(c.object, "total_chunks")) |v| ins.ckpt_total = @intCast(v);
            if (getStr(c.object, "reason")) |v| ins.ckpt_reason = v;
        }
    }
    // First warning / error, mirroring the CLI which surfaces errors[0].
    if (r.get("warnings")) |w| {
        if (w == .array and w.array.items.len > 0 and w.array.items[0] == .string)
            ins.warning = w.array.items[0].string;
    }
    if (r.get("errors")) |e| {
        if (e == .array and e.array.items.len > 0 and e.array.items[0] == .string)
            ins.error_msg = e.array.items[0].string;
    }
    return ins;
}

/// Minimal legacy text-mode fallback, mirroring the CLI's second path.
fn legacy(line: []const u8) ?Event {
    if (std.mem.startsWith(u8, line, "PHASE:")) {
        return .{ .phase = Phase.fromStr(line["PHASE:".len..]) orelse return null };
    }
    if (std.mem.eql(u8, line, "DONE")) return .done;
    if (std.mem.startsWith(u8, line, "CHECKPOINT:")) {
        const rest = line["CHECKPOINT:".len..];
        var it = std.mem.splitScalar(u8, rest, ':');
        const code = it.first();
        return .{ .checkpoint = .{ .code = code, .detail = it.rest() } };
    }
    // "PROGRESS:3/120 chunks" or bare "3/120 chunks"
    if (std.mem.indexOf(u8, line, "chunks")) |_| {
        var body = line;
        if (std.mem.startsWith(u8, body, "PROGRESS:")) body = body["PROGRESS:".len..];
        if (std.mem.indexOfScalar(u8, body, '/')) |slash| {
            const cur = std.fmt.parseInt(u32, std.mem.trim(u8, body[0..slash], " "), 10) catch return null;
            var tail = body[slash + 1 ..];
            if (std.mem.indexOfScalar(u8, tail, ' ')) |sp| tail = tail[0..sp];
            const total = std.fmt.parseInt(u32, tail, 10) catch return null;
            if (total == 0) return null;
            return .{ .progress = .{ .current = cur, .total = total } };
        }
    }
    return null;
}

// --------------------------------------------------------------------- tests

fn parseOne(arena: std.mem.Allocator, line: []const u8) ?Event {
    return parseLine(arena, line);
}

test "parseLine: phase + progress + done" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ph = parseOne(a, "{\"type\":\"phase\",\"phase\":\"INFERENCE\",\"ts_ms\":1,\"job_id\":\"x\"}").?;
    try std.testing.expectEqual(Phase.inference, ph.phase);

    const pr = parseOne(a, "{\"type\":\"progress\",\"current_chunk\":30,\"total_chunks\":120}").?;
    try std.testing.expectEqual(@as(u32, 30), pr.progress.current);
    try std.testing.expectEqual(@as(u32, 120), pr.progress.total);

    try std.testing.expect(parseOne(a, "{\"type\":\"done\",\"output\":\"/x.mp3\"}").? == .done);
}

test "parseLine: metadata + zero-total progress rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const br = parseOne(a, "{\"type\":\"metadata\",\"key\":\"backend_resolved\",\"value\":\"mlx\"}").?;
    try std.testing.expectEqual(config.Backend.mlx, br.backend_resolved);

    const tc = parseOne(a, "{\"type\":\"metadata\",\"key\":\"total_chars\",\"value\":271000}").?;
    try std.testing.expectEqual(@as(u64, 271000), tc.total_chars);

    try std.testing.expect(parseOne(a, "{\"type\":\"progress\",\"current_chunk\":0,\"total_chunks\":0}") == null);
}

test "parseLine: inspection payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const line =
        "{\"type\":\"inspection\",\"result\":{\"total_chars\":271000,\"total_chunks\":452," ++
        "\"chapter_count\":9,\"resolved_backend\":\"mlx\"," ++
        "\"epub_metadata\":{\"title\":\"Gatsby\",\"author\":\"Fitzgerald\",\"has_cover\":true}," ++
        "\"checkpoint\":{\"exists\":true,\"resume_compatible\":true,\"completed_chunks\":128,\"total_chunks\":452}," ++
        "\"warnings\":[],\"errors\":[]}}";
    const ev = parseOne(a, line).?;
    const ins = ev.inspection;
    try std.testing.expectEqual(@as(u64, 271000), ins.total_chars);
    try std.testing.expectEqual(@as(u32, 452), ins.total_chunks);
    try std.testing.expectEqual(@as(u32, 9), ins.chapter_count);
    try std.testing.expectEqualStrings("Gatsby", ins.title);
    try std.testing.expectEqualStrings("Fitzgerald", ins.author);
    try std.testing.expect(ins.has_cover);
    try std.testing.expect(ins.ckpt_exists and ins.ckpt_resume_compatible);
    try std.testing.expectEqual(@as(u32, 128), ins.ckpt_completed);
}

test "parseLine: legacy fallback + junk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqual(Phase.exporting, parseOne(a, "PHASE:EXPORTING").?.phase);
    const pr = parseOne(a, "PROGRESS:5/10 chunks").?;
    try std.testing.expectEqual(@as(u32, 5), pr.progress.current);
    try std.testing.expect(parseOne(a, "some random torch warning") == null);
    try std.testing.expect(parseOne(a, "") == null);
}
