const std = @import("std");

const Allocator = std.mem.Allocator;

const max_outputs = 16;
const max_name_len = 96;
const max_workspace_name_len = 128;

const Direction = enum {
    up,
    down,

    fn parse(arg: []const u8) ?Direction {
        if (std.mem.eql(u8, arg, "up")) return .up;
        if (std.mem.eql(u8, arg, "down")) return .down;
        return null;
    }
};

const Rect = struct {
    x: i64,
    y: i64,
};

const Output = struct {
    name: [max_name_len]u8,
    name_len: usize,
    rect: Rect,

    fn nameSlice(self: *const Output) []const u8 {
        return self.name[0..self.name_len];
    }
};

const FocusedWorkspace = struct {
    name: [max_workspace_name_len]u8,
    name_len: usize,
    output: [max_name_len]u8,
    output_len: usize,

    fn nameSlice(self: *const FocusedWorkspace) []const u8 {
        return self.name[0..self.name_len];
    }

    fn outputSlice(self: *const FocusedWorkspace) []const u8 {
        return self.output[0..self.output_len];
    }
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();
    const direction_arg = args.next() orelse return usage();
    if (args.next() != null) return usage();

    const direction = Direction.parse(direction_arg) orelse return usage();

    const outputs_json = try swaymsgJson(allocator, "get_outputs");
    defer allocator.free(outputs_json);

    const workspaces_json = try swaymsgJson(allocator, "get_workspaces");
    defer allocator.free(workspaces_json);

    var outputs = [_]Output{undefined} ** max_outputs;
    const output_count = try activeOutputs(allocator, outputs_json, &outputs);
    if (output_count == 0) return error.NoActiveOutputs;

    sortOutputs(outputs[0..output_count]);

    const focused = try focusedWorkspace(allocator, workspaces_json);
    const monitor_index = outputIndex(outputs[0..output_count], focused.outputSlice()) orelse return error.FocusedOutputNotFound;
    const monitor_number = monitor_index + 1;
    const current_slot = parseWorkspaceSlot(focused.nameSlice(), monitor_number);
    var command_buf: [max_workspace_name_len + 64]u8 = undefined;
    const command = try nextWorkspaceCommand(allocator, workspaces_json, focused.outputSlice(), &command_buf, direction, current_slot, monitor_number) orelse return;

    try switchWorkspace(allocator, command);
}

fn usage() error{InvalidArgs} {
    std.debug.print("usage: sway-workspace up|down\n", .{});
    return error.InvalidArgs;
}

fn swaymsgJson(allocator: Allocator, message_type: []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "swaymsg", "-t", message_type },
        .max_output_bytes = 256 * 1024,
    });
    defer allocator.free(result.stderr);

    if (!termSucceeded(result.term)) {
        std.debug.print("{s}", .{result.stderr});
        allocator.free(result.stdout);
        return error.SwaymsgFailed;
    }

    return result.stdout;
}

fn switchWorkspace(allocator: Allocator, command: []const u8) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "swaymsg", command },
        .max_output_bytes = 32 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!termSucceeded(result.term)) {
        std.debug.print("{s}", .{result.stderr});
        return error.SwaymsgFailed;
    }
}

fn termSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn nextWorkspaceCommand(
    allocator: Allocator,
    workspaces_json: []const u8,
    output: []const u8,
    buf: []u8,
    direction: Direction,
    current_slot: ?usize,
    monitor_number: usize,
) !?[]const u8 {
    // Unknown workspace names are left alone when moving down. Numbered
    // startup workspaces and managed workspaces share the same slot numbering.
    const slot = current_slot orelse 1;
    const next_slot = switch (direction) {
        .up => try std.math.add(usize, slot, 1),
        .down => if (current_slot == null or slot <= 1) return null else slot - 1,
    };

    // Reuse a numbered workspace on this output instead of creating a managed
    // workspace that Waybar would display with the same label.
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, workspaces_json, .{});
    defer parsed.deinit();
    for (parsed.value.array.items) |item| {
        const object = item.object;
        if (!std.mem.eql(u8, object.get("output").?.string, output)) continue;
        const name = object.get("name").?.string;
        if (parseWorkspaceSlot(name, monitor_number) == next_slot) {
            return try std.fmt.bufPrint(buf, "workspace --no-auto-back-and-forth {s}", .{name});
        }
    }

    return try std.fmt.bufPrint(buf, "workspace --no-auto-back-and-forth mon{d}_{d}", .{ monitor_number, next_slot });
}

fn activeOutputs(allocator: Allocator, data: []const u8, outputs: *[max_outputs]Output) !usize {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    const array = parsed.value.array;
    var count: usize = 0;
    for (array.items) |item| {
        const object = item.object;
        if (!object.get("active").?.bool) continue;
        if (count == outputs.len) return error.TooManyOutputs;

        const name = object.get("name").?.string;
        const rect = object.get("rect").?.object;

        outputs[count] = .{
            .name = undefined,
            .name_len = try copyBounded(name, &outputs[count].name),
            .rect = .{
                .x = rect.get("x").?.integer,
                .y = rect.get("y").?.integer,
            },
        };
        count += 1;
    }

    return count;
}

fn focusedWorkspace(allocator: Allocator, data: []const u8) !FocusedWorkspace {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    const array = parsed.value.array;
    for (array.items) |item| {
        const object = item.object;
        if (!object.get("focused").?.bool) continue;

        const name = object.get("name").?.string;
        const output = object.get("output").?.string;

        var workspace: FocusedWorkspace = .{
            .name = undefined,
            .name_len = 0,
            .output = undefined,
            .output_len = 0,
        };
        workspace.name_len = try copyBounded(name, &workspace.name);
        workspace.output_len = try copyBounded(output, &workspace.output);
        return workspace;
    }

    return error.NoFocusedWorkspace;
}

fn copyBounded(src: []const u8, dest: []u8) !usize {
    if (src.len > dest.len) return error.NameTooLong;
    @memcpy(dest[0..src.len], src);
    return src.len;
}

fn sortOutputs(outputs: []Output) void {
    std.mem.sort(Output, outputs, {}, struct {
        fn lessThan(_: void, lhs: Output, rhs: Output) bool {
            if (lhs.rect.x != rhs.rect.x) return lhs.rect.x < rhs.rect.x;
            if (lhs.rect.y != rhs.rect.y) return lhs.rect.y < rhs.rect.y;
            return std.mem.lessThan(u8, lhs.nameSlice(), rhs.nameSlice());
        }
    }.lessThan);
}

fn outputIndex(outputs: []const Output, name: []const u8) ?usize {
    for (outputs, 0..) |output, i| {
        if (std.mem.eql(u8, output.nameSlice(), name)) return i;
    }
    return null;
}

fn parseManagedWorkspaceSlot(name: []const u8, monitor_number: usize) ?usize {
    var prefix_buf: [32]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "mon{d}_", .{monitor_number}) catch return null;
    if (!std.mem.startsWith(u8, name, prefix)) return null;

    const slot_text = name[prefix.len..];
    if (slot_text.len == 0) return null;
    return std.fmt.parseUnsigned(usize, slot_text, 10) catch null;
}

fn parseWorkspaceSlot(name: []const u8, monitor_number: usize) ?usize {
    const slot = parseManagedWorkspaceSlot(name, monitor_number) orelse
        (std.fmt.parseUnsigned(usize, name, 10) catch return null);
    return if (slot > 0) slot else null;
}

test "workspace slot parsing" {
    try std.testing.expectEqual(@as(?usize, 1), parseWorkspaceSlot("mon1_1", 1));
    try std.testing.expectEqual(@as(?usize, 42), parseWorkspaceSlot("mon3_42", 3));
    try std.testing.expectEqual(@as(?usize, null), parseWorkspaceSlot("mon2_1", 1));
    try std.testing.expectEqual(@as(?usize, 2), parseWorkspaceSlot("2", 1));
    try std.testing.expectEqual(@as(?usize, null), parseWorkspaceSlot("mon1_0", 1));
    try std.testing.expectEqual(@as(?usize, null), parseWorkspaceSlot("0", 1));
    try std.testing.expectEqual(@as(?usize, null), parseWorkspaceSlot("web", 1));
}

test "down stops at the first workspace on each monitor" {
    var buf: [max_workspace_name_len + 64]u8 = undefined;
    for (1..5) |monitor| {
        try std.testing.expectEqual(@as(?[]const u8, null), try nextWorkspaceCommand(std.testing.allocator, "[]", "DP-1", &buf, .down, 1, monitor));
        try std.testing.expectEqual(@as(?[]const u8, null), try nextWorkspaceCommand(std.testing.allocator, "[]", "DP-1", &buf, .down, null, monitor));
    }
}

test "navigation preserves numbering and reuses workspaces only on the focused output" {
    var buf: [max_workspace_name_len + 64]u8 = undefined;
    const workspaces =
        \\[ {"name":"1","output":"DP-1"}, {"name":"2","output":"HDMI-A-1"}, {"name":"mon2_3","output":"DP-1"} ]
    ;
    try std.testing.expectEqualStrings("workspace --no-auto-back-and-forth mon2_2", (try nextWorkspaceCommand(std.testing.allocator, workspaces, "DP-1", &buf, .up, 1, 2)).?);
    try std.testing.expectEqualStrings("workspace --no-auto-back-and-forth 1", (try nextWorkspaceCommand(std.testing.allocator, workspaces, "DP-1", &buf, .down, 2, 2)).?);
    try std.testing.expectEqualStrings("workspace --no-auto-back-and-forth mon2_3", (try nextWorkspaceCommand(std.testing.allocator, workspaces, "DP-1", &buf, .up, 2, 2)).?);
    try std.testing.expectEqualStrings("workspace --no-auto-back-and-forth mon2_2", (try nextWorkspaceCommand(std.testing.allocator, workspaces, "DP-1", &buf, .down, 3, 2)).?);
    try std.testing.expectEqualStrings("workspace --no-auto-back-and-forth 2", (try nextWorkspaceCommand(std.testing.allocator, workspaces, "HDMI-A-1", &buf, .up, 1, 1)).?);
    try std.testing.expectEqualStrings("workspace --no-auto-back-and-forth mon1_2", (try nextWorkspaceCommand(std.testing.allocator, "[]", "HDMI-A-1", &buf, .up, null, 1)).?);
}

test "output sorting" {
    var outputs = [_]Output{
        .{ .name = undefined, .name_len = 0, .rect = .{ .x = 1920, .y = 0 } },
        .{ .name = undefined, .name_len = 0, .rect = .{ .x = 0, .y = 0 } },
    };
    outputs[0].name_len = try copyBounded("DP-1", &outputs[0].name);
    outputs[1].name_len = try copyBounded("HDMI-A-1", &outputs[1].name);
    sortOutputs(&outputs);
    try std.testing.expectEqualStrings("HDMI-A-1", outputs[0].nameSlice());
    try std.testing.expectEqualStrings("DP-1", outputs[1].nameSlice());
}
