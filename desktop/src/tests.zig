const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const testing = std.testing;

// Pure-logic module tests (config/argv builder + backend event parser + glue).
test {
    _ = @import("config.zig");
    _ = @import("events.zig");
    _ = @import("apple_host.zig");
    _ = @import("shell.zig");
}

const AppUi = main.AppUi;
const Model = main.Model;
const Msg = main.Msg;
const AppMarkup = canvas.MarkupView(Model, Msg);

fn buildTree(arena: std.mem.Allocator, model: *const Model) !AppUi.Tree {
    var view = try AppMarkup.init(arena, main.app_markup);
    var ui = AppUi.init(arena);
    const node = view.build(&ui, model) catch |err| {
        if (err == error.MarkupBuild) {
            std.debug.print("app.native:{d}:{d}: {s}\n", .{ view.diagnostic.line, view.diagnostic.column, view.diagnostic.message });
        }
        return err;
    };
    return ui.finalize(node);
}

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}

fn hasText(widget: canvas.Widget, text: []const u8) bool {
    if (std.mem.indexOf(u8, widget.text, text) != null) return true;
    for (widget.children) |child| {
        if (hasText(child, text)) return true;
    }
    return false;
}

test "checking screen builds and lays out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel(); // screen == .checking
    const tree = try buildTree(arena, &model);

    var nodes: [512]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, native_sdk.geometry.RectF.init(0, 0, 1040, 700), &nodes);
    try testing.expect(layout.nodes.len > 0);
    try testing.expect(hasText(tree.root, "Checking dependencies"));
}

test "setup screen renders failing checks with fixes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.screen = .setup;
    model.check_count = 1;
    model.checks[0].name.set("FFmpeg");
    model.checks[0].ok = false;
    model.checks[0].message.set("not found on PATH");
    model.checks[0].fix.set("brew install ffmpeg");

    const tree = try buildTree(arena, &model);
    try testing.expect(hasText(tree.root, "Setup required"));
    try testing.expect(hasText(tree.root, "brew install ffmpeg"));
}

test "library screen shows a selected, ready book and its settings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.screen = .library;
    model.book_count = 1;
    model.selected = 0;
    model.books[0].input.set("/books/gatsby.epub");
    model.books[0].output.set("/books/gatsby.mp3");
    model.books[0].title.set("The Great Gatsby");
    model.books[0].author.set("F. Scott Fitzgerald");
    model.books[0].total_chunks = 452;
    model.books[0].total_chars = 271000;
    model.books[0].chapter_count = 9;
    model.books[0].status = .ready;

    const tree = try buildTree(arena, &model);
    try testing.expect(hasText(tree.root, "The Great Gatsby"));
    try testing.expect(hasText(tree.root, "F. Scott Fitzgerald"));
    try testing.expect(hasText(tree.root, "Settings"));
    // The convert action is enabled when a ready book exists.
    _ = findByText(tree.root, .button, "Convert All") orelse return error.MissingConvertButton;
    // Voice cycle button carries the current voice label.
    try testing.expect(hasText(tree.root, "Heart"));
}

test "cycling voice and toggling format mutate the config" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    // Drive update() directly for the pure (effect-free) arms.
    var model = main.initialModel();
    model.screen = .library;

    try testing.expectEqualStrings("af_heart", model.cfg.voice);
    dispatchPure(&model, .cycle_voice);
    try testing.expectEqualStrings("af_bella", model.cfg.voice);

    try testing.expect(model.cfg.format == .mp3);
    dispatchPure(&model, .set_mlx);
    try testing.expect(model.cfg.backend == .mlx);
    try testing.expect(model.cfg.use_mps); // mlx forces MPS on

    dispatchPure(&model, .toggle_normalize);
    try testing.expect(model.cfg.normalize);
}

// A tiny effects shim: the pure update arms never touch `fx`, so a stack
// Effects value is enough to exercise them without a runtime.
fn dispatchPure(model: *Model, msg: Msg) void {
    const App = native_sdk.UiApp(Model, Msg);
    var fx: App.Effects = undefined;
    main.update(model, msg, &fx);
}
