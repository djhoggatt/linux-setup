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
    base_workspace_number: usize,
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

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const direction_arg = args.next() orelse return usage();
    if (args.next() != null) return usage();

    const direction = Direction.parse(direction_arg) orelse return usage();

    const outputs_json = try swaymsgJson(allocator, io, "get_outputs");
    defer allocator.free(outputs_json);

    const workspaces_json = try swaymsgJson(allocator, io, "get_workspaces");
    defer allocator.free(workspaces_json);

    var outputs = [_]Output{undefined} ** max_outputs;
    const output_count = try activeOutputs(allocator, outputs_json, &outputs);
    if (output_count == 0) return error.NoActiveOutputs;

    sortOutputs(outputs[0..output_count]);

    const focused = try focusedWorkspace(allocator, workspaces_json);
    const monitor_index = outputIndex(outputs[0..output_count], focused.outputSlice()) orelse return error.FocusedOutputNotFound;
    const monitor_number = monitor_index + 1;
    const base_workspace_number = outputs[monitor_index].base_workspace_number;

    const current_slot = parseManagedWorkspaceSlot(focused.nameSlice(), monitor_number);
    var command_buf: [max_workspace_name_len + 32]u8 = undefined;
    const command = try nextWorkspaceCommand(&command_buf, direction, current_slot, monitor_number, base_workspace_number);

    try switchWorkspace(allocator, io, command);
}

fn usage() error{InvalidArgs} {
    std.debug.print("usage: sway-workspace up|down\n", .{});
    return error.InvalidArgs;
}

fn swaymsgJson(allocator: Allocator, io: std.Io, message_type: []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "swaymsg", "-t", message_type },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(32 * 1024),
    });
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("{s}", .{result.stderr});
        allocator.free(result.stdout);
        return error.SwaymsgFailed;
    }

    return result.stdout;
}

fn switchWorkspace(allocator: Allocator, io: std.Io, command: []const u8) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "swaymsg", command },
        .stdout_limit = .limited(32 * 1024),
        .stderr_limit = .limited(32 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("{s}", .{result.stderr});
        return error.SwaymsgFailed;
    }
}

fn nextWorkspaceCommand(
    buf: []u8,
    direction: Direction,
    current_slot: ?usize,
    monitor_number: usize,
    base_workspace_number: usize,
) ![]const u8 {
    const next_slot = switch (direction) {
        .up => if (current_slot) |slot| slot + 1 else 1,
        .down => if (current_slot) |slot| if (slot > 1) slot - 1 else null else null,
    };

    if (next_slot) |slot| {
        return std.fmt.bufPrint(buf, "workspace mon{d}_{d}", .{ monitor_number, slot });
    }

    return std.fmt.bufPrint(buf, "workspace number {d}", .{base_workspace_number});
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
            .base_workspace_number = count + 1,
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

test "managed workspace slot parsing" {
    try std.testing.expectEqual(@as(?usize, 1), parseManagedWorkspaceSlot("mon1_1", 1));
    try std.testing.expectEqual(@as(?usize, 42), parseManagedWorkspaceSlot("mon3_42", 3));
    try std.testing.expectEqual(@as(?usize, null), parseManagedWorkspaceSlot("mon2_1", 1));
    try std.testing.expectEqual(@as(?usize, null), parseManagedWorkspaceSlot("2", 1));
}

test "workspace command navigation" {
    var buf: [max_workspace_name_len + 32]u8 = undefined;

    try std.testing.expectEqualStrings(
        "workspace mon1_1",
        try nextWorkspaceCommand(&buf, .up, null, 1, 2),
    );
    try std.testing.expectEqualStrings(
        "workspace number 2",
        try nextWorkspaceCommand(&buf, .down, null, 1, 2),
    );
    try std.testing.expectEqualStrings(
        "workspace number 2",
        try nextWorkspaceCommand(&buf, .down, 1, 1, 2),
    );
    try std.testing.expectEqualStrings(
        "workspace mon1_1",
        try nextWorkspaceCommand(&buf, .down, 2, 1, 2),
    );
    try std.testing.expectEqualStrings(
        "workspace number 1",
        try nextWorkspaceCommand(&buf, .down, 1, 2, 1),
    );
}

test "output sorting" {
    var outputs = [_]Output{
        .{ .name = undefined, .name_len = 0, .base_workspace_number = 1, .rect = .{ .x = 1920, .y = 0 } },
        .{ .name = undefined, .name_len = 0, .base_workspace_number = 2, .rect = .{ .x = 0, .y = 0 } },
    };
    outputs[0].name_len = try copyBounded("DP-1", &outputs[0].name);
    outputs[1].name_len = try copyBounded("HDMI-A-1", &outputs[1].name);

    sortOutputs(&outputs);

    try std.testing.expectEqualStrings("HDMI-A-1", outputs[0].nameSlice());
    try std.testing.expectEqualStrings("DP-1", outputs[1].nameSlice());
    try std.testing.expectEqual(@as(usize, 2), outputs[0].base_workspace_number);
    try std.testing.expectEqual(@as(usize, 1), outputs[1].base_workspace_number);
}
