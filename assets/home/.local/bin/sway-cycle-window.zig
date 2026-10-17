//! Cycle windows on visible workspaces across monitors, with wraparound.
//! Built with the installer's pinned Zig 0.15.2.

const std = @import("std");
const Allocator = std.mem.Allocator;

const MAX_RESPONSE_BYTES = 16 * 1024 * 1024;

const Direction = enum {
    next,
    prev,
};

const Position = struct {
    x: i64 = 0,
    y: i64 = 0,
};

const Node = struct {
    id: i64 = 0,
    type: []const u8 = "",
    rect: Position = .{},
    focused: bool = false,
    app_id: ?[]const u8 = null,
    window: ?i64 = null,
    nodes: []const Node = &.{},
    floating_nodes: []const Node = &.{},
};

const Workspace = struct {
    id: i64,
    visible: bool,
};

const Window = struct {
    id: i64,
    focused: bool = false,
};

const CommandResult = struct {
    success: bool,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const direction = try read_direction(allocator);
    const treeJson = try run_swaymsg(allocator, &.{ "swaymsg", "-r", "-t", "get_tree" });
    const workspaceJson = try run_swaymsg(allocator, &.{ "swaymsg", "-r", "-t", "get_workspaces" });

    const tree = try parse_response(Node, allocator, treeJson);
    const workspaces = try parse_response([]const Workspace, allocator, workspaceJson);

    var windows: std.ArrayList(Window) = .empty;
    try collect_windows(allocator, tree, workspaces, &windows);

    const windowId = select_window(windows.items, direction) orelse return;
    try focus_window(allocator, windowId);
}

fn read_direction(allocator: Allocator) !Direction {
    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);

    if (arguments.len != 2) {
        return print_usage();
    }

    return std.meta.stringToEnum(Direction, arguments[1]) orelse print_usage();
}

fn print_usage() error{InvalidArguments} {
    std.debug.print("Usage: sway-cycle-window next|prev\n", .{});
    return error.InvalidArguments;
}

fn collect_windows(
    allocator: Allocator,
    node: Node,
    workspaces: []const Workspace,
    windows: *std.ArrayList(Window),
) !void {
    const isWorkspace = std.mem.eql(u8, node.type, "workspace");
    if (isWorkspace and !workspace_is_visible(node.id, workspaces)) {
        return;
    }

    const isWindow = node.app_id != null or node.window != null;
    if (isWindow) {
        try windows.append(allocator, .{
            .id = node.id,
            .focused = node.focused,
        });
        return;
    }

    var children: std.ArrayList(Node) = .empty;
    defer children.deinit(allocator);

    try children.appendSlice(allocator, node.nodes);
    try children.appendSlice(allocator, node.floating_nodes);

    // Stable sorting preserves layout order when tabbed windows share a position.
    std.mem.sort(Node, children.items, {}, position_before);

    for (children.items) |child| {
        try collect_windows(allocator, child, workspaces, windows);
    }
}

fn workspace_is_visible(workspaceId: i64, workspaces: []const Workspace) bool {
    for (workspaces) |workspace| {
        if (workspace.id != workspaceId) continue;
        return workspace.visible;
    }

    return false;
}

fn position_before(_: void, first: Node, second: Node) bool {
    if (first.rect.x != second.rect.x) {
        return first.rect.x < second.rect.x;
    }

    return first.rect.y < second.rect.y;
}

fn select_window(windows: []const Window, direction: Direction) ?i64 {
    if (windows.len == 0) return null;

    const currentIndex = focused_window_index(windows) orelse {
        if (direction == .next) return windows[0].id;
        return windows[windows.len - 1].id;
    };

    if (direction == .next) {
        const nextIndex = (currentIndex + 1) % windows.len;
        return windows[nextIndex].id;
    }

    if (currentIndex == 0) return windows[windows.len - 1].id;
    return windows[currentIndex - 1].id;
}

fn focused_window_index(windows: []const Window) ?usize {
    for (windows, 0..) |window, index| {
        if (window.focused) return index;
    }

    return null;
}

// Parsed values live in the caller's arena until the command finishes.
fn parse_response(comptime Response: type, allocator: Allocator, json: []const u8) !Response {
    return std.json.parseFromSliceLeaky(Response, allocator, json, .{
        .ignore_unknown_fields = true,
    });
}

fn focus_window(allocator: Allocator, windowId: i64) !void {
    const command = try std.fmt.allocPrint(allocator, "[con_id={d}] focus", .{windowId});
    const responseJson = try run_swaymsg(allocator, &.{ "swaymsg", "-r", command });
    const results = try parse_response([]const CommandResult, allocator, responseJson);

    if (results.len == 0) return error.EmptyCommandResponse;

    for (results) |result| {
        if (!result.success) return error.FocusFailed;
    }
}

fn run_swaymsg(allocator: Allocator, arguments: []const []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = arguments,
        .max_output_bytes = MAX_RESPONSE_BYTES,
    });
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);

    if (result.term != .Exited or result.term.Exited != 0) {
        std.debug.print("sway-cycle-window: {s}\n", .{result.stderr});
        return error.SwaymsgFailed;
    }

    return result.stdout;
}

fn expect_window(expectedId: ?i64, windows: []const Window, direction: Direction) !void {
    try std.testing.expectEqual(expectedId, select_window(windows, direction));
}

test "cycle wraps at both ends and advances from the middle" {
    var windows = [_]Window{
        .{ .id = 10, .focused = true },
        .{ .id = 20 },
        .{ .id = 30 },
    };

    try expect_window(20, &windows, .next);
    try expect_window(30, &windows, .prev);

    windows[0].focused = false;
    windows[1].focused = true;

    try expect_window(30, &windows, .next);
    try expect_window(10, &windows, .prev);

    windows[1].focused = false;
    windows[2].focused = true;

    try expect_window(10, &windows, .next);
    try expect_window(20, &windows, .prev);
}

test "empty, single window, and no focused window" {
    try expect_window(null, &.{}, .next);
    try expect_window(null, &.{}, .prev);

    const singleWindow = [_]Window{.{ .id = 10, .focused = true }};
    try expect_window(10, &singleWindow, .next);
    try expect_window(10, &singleWindow, .prev);

    const unfocusedWindows = [_]Window{ .{ .id = 10 }, .{ .id = 20 } };
    try expect_window(10, &unfocusedWindows, .next);
    try expect_window(20, &unfocusedWindows, .prev);
}

test "monitor order, nested windows, floating windows, and hidden workspaces" {
    const rightMonitor = Node{
        .rect = .{ .x = 100 },
        .nodes = &.{.{
            .type = "workspace",
            .id = 2,
            .nodes = &.{.{ .id = 20, .app_id = "test" }},
        }},
    };

    const leftWorkspace = Node{
        .type = "workspace",
        .id = 1,
        .nodes = &.{
            .{
                .rect = .{ .x = 50 },
                .nodes = &.{
                    .{ .id = 11, .app_id = "test" },
                    .{ .id = 13, .app_id = "test" },
                },
            },
            .{ .id = 10, .window = 123 },
        },
        .floating_nodes = &.{.{ .id = 12, .app_id = "test", .rect = .{ .x = 75 } }},
    };

    const hiddenWorkspace = Node{
        .type = "workspace",
        .id = 3,
        .nodes = &.{.{ .id = 30, .app_id = "hidden" }},
    };

    const leftMonitor = Node{ .nodes = &.{ leftWorkspace, hiddenWorkspace } };
    const tree = Node{ .nodes = &.{ rightMonitor, leftMonitor } };
    const workspaces = [_]Workspace{
        .{ .id = 1, .visible = true },
        .{ .id = 2, .visible = true },
        .{ .id = 3, .visible = false },
    };

    const allocator = std.testing.allocator;
    var windows: std.ArrayList(Window) = .empty;
    defer windows.deinit(allocator);

    try collect_windows(allocator, tree, &workspaces, &windows);

    const expectedIds = [_]i64{ 10, 11, 13, 12, 20 };
    try std.testing.expectEqual(expectedIds.len, windows.items.len);

    for (expectedIds, windows.items) |expectedId, window| {
        try std.testing.expectEqual(expectedId, window.id);
    }
}

test "Sway responses accept extra fields and null window identifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json =
        \\{"id":1,"type":"root","name":"root","app_id":null,"window":null,
        \\ "rect":{"x":0,"y":0,"width":1920,"height":1080},"nodes":[]}
    ;
    const tree = try parse_response(Node, allocator, json);

    try std.testing.expectEqual(@as(i64, 1), tree.id);
    try std.testing.expectEqual(@as(?i64, null), tree.window);
    try std.testing.expectEqual(@as(usize, 0), tree.nodes.len);
}
