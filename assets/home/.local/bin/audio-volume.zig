const std = @import("std");

const command_output_max = 256 * 1024;
const set_param_max = 1024;
const channel_array_max = 512;
const step_db = 1.5;
const min_nonzero_volume = 0.001;

const Action = enum {
    up,
    down,
    mute,
    status,
};

const SinkState = struct {
    volume: f64 = 1.0,
    channel_sum: f64 = 0.0,
    channel_count: usize = 0,

    fn channelAverage(self: SinkState) f64 {
        if (self.channel_count == 0) {
            return 1.0;
        }

        return self.channel_sum / @as(f64, @floatFromInt(self.channel_count));
    }

    fn effectiveVolume(self: SinkState) f64 {
        return self.volume * self.channelAverage();
    }
};

fn trimAscii(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, &std.ascii.whitespace);
}

fn runCapture(argv: []const []const u8, out: []u8) ![]const u8 {
    var child_storage: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&child_storage);

    var child = std.process.Child.init(argv, fba.allocator());
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();
    const stdout = child.stdout.?;
    const n = try stdout.readAll(out);
    const term = try child.wait();

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                return error.CommandFailed;
            }
        },
        else => return error.CommandFailed,
    }

    return trimAscii(out[0..n]);
}

fn runWait(argv: []const []const u8) !void {
    var child_storage: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&child_storage);

    var child = std.process.Child.init(argv, fba.allocator());
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    try child.spawn();
    const term = try child.wait();

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                return error.CommandFailed;
            }
        },
        else => return error.CommandFailed,
    }
}

fn parseAction(arg: []const u8) ?Action {
    if (std.mem.eql(u8, arg, "up")) {
        return .up;
    }

    if (std.mem.eql(u8, arg, "down")) {
        return .down;
    }

    if (std.mem.eql(u8, arg, "mute")) {
        return .mute;
    }

    if (std.mem.eql(u8, arg, "status")) {
        return .status;
    }

    return null;
}

fn lineValue(line: []const u8, prefix: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, line, prefix) orelse return null;
    var value = line[start + prefix.len ..];

    if (std.mem.startsWith(u8, value, "\"")) {
        value = value[1..];
        const end = std.mem.indexOfScalar(u8, value, '"') orelse return null;
        return value[0..end];
    }

    return trimAscii(value);
}

fn parseNodeId(line: []const u8) ?u32 {
    const trimmed = trimAscii(line);
    if (!std.mem.startsWith(u8, trimmed, "id ")) {
        return null;
    }

    const rest = trimmed["id ".len..];
    const end = std.mem.indexOfScalar(u8, rest, ',') orelse return null;
    return std.fmt.parseInt(u32, rest[0..end], 10) catch null;
}

fn findSinkNodeId(nodes: []const u8, sink_name: []const u8) ?u32 {
    var current_id: ?u32 = null;
    var lines = std.mem.splitScalar(u8, nodes, '\n');

    while (lines.next()) |line| {
        if (parseNodeId(line)) |id| {
            current_id = id;
            continue;
        }

        const node_name = lineValue(line, "node.name = ") orelse continue;
        if (current_id) |id| {
            if (std.mem.eql(u8, node_name, sink_name)) {
                return id;
            }
        }
    }

    return null;
}

fn parseFloatLine(line: []const u8) ?f64 {
    const trimmed = trimAscii(line);
    if (!std.mem.startsWith(u8, trimmed, "Float ")) {
        return null;
    }

    return std.fmt.parseFloat(f64, trimAscii(trimmed["Float ".len..])) catch null;
}

fn parseSinkState(props: []const u8) ?SinkState {
    const Mode = enum {
        none,
        volume,
        channel_volumes,
    };

    var state: SinkState = .{};
    var found_volume = false;
    var mode: Mode = .none;
    var lines = std.mem.splitScalar(u8, props, '\n');

    while (lines.next()) |line| {
        const trimmed = trimAscii(line);

        if (std.mem.startsWith(u8, trimmed, "Object:") and found_volume) {
            break;
        }

        if (std.mem.startsWith(u8, trimmed, "Prop: key ")) {
            mode = .none;

            if (std.mem.indexOf(u8, trimmed, ":volume ") != null) {
                mode = .volume;
                continue;
            }

            if (std.mem.indexOf(u8, trimmed, ":channelVolumes ") != null) {
                mode = .channel_volumes;
                continue;
            }
        }

        const value = parseFloatLine(trimmed) orelse continue;
        switch (mode) {
            .none => {},
            .volume => {
                state.volume = value;
                found_volume = true;
                mode = .none;
            },
            .channel_volumes => {
                state.channel_sum += value;
                state.channel_count += 1;
            },
        }
    }

    if (!found_volume) {
        return null;
    }

    return state;
}

fn isMuted(mute_output: []const u8) bool {
    return std.mem.indexOf(u8, mute_output, "yes") != null;
}

fn clampVolume(volume: f64) f64 {
    if (volume < 0.0) {
        return 0.0;
    }

    if (volume > 1.0) {
        return 1.0;
    }

    return volume;
}

fn volumeAfterStep(current: f64, action: Action) f64 {
    const ratio = @exp(@log(10.0) * step_db / 20.0);

    const next = switch (action) {
        .up => if (current <= 0.0) min_nonzero_volume else current * ratio,
        .down => blk: {
            const reduced = current / ratio;
            if (reduced < min_nonzero_volume) {
                break :blk 0.0;
            }

            break :blk reduced;
        },
        else => current,
    };

    return clampVolume(next);
}

fn writeUnityChannels(out: []u8, channel_count: usize) ![]const u8 {
    var stream = std.io.fixedBufferStream(out);
    const writer = stream.writer();
    const count = if (channel_count == 0) 1 else channel_count;

    try writer.writeAll("[ ");
    for (0..count) |i| {
        if (i > 0) {
            try writer.writeAll(", ");
        }

        try writer.writeAll("1.0");
    }
    try writer.writeAll(" ]");

    return stream.getWritten();
}

fn setNodeVolume(node_id: u32, volume: f64, channel_count: usize) !void {
    var channel_buf: [channel_array_max]u8 = undefined;
    const channels = try writeUnityChannels(&channel_buf, channel_count);

    var node_id_buf: [16]u8 = undefined;
    const node_id_arg = try std.fmt.bufPrint(&node_id_buf, "{d}", .{node_id});

    var props_buf: [set_param_max]u8 = undefined;
    const props = try std.fmt.bufPrint(
        &props_buf,
        "{{ volume: {d:.6}, channelVolumes: {s}, softVolumes: {s} }}",
        .{ volume, channels, channels },
    );

    try runWait(&.{ "pw-cli", "set-param", node_id_arg, "Props", props });
}

fn printStatus(volume: f64) !void {
    var stdout = std.fs.File.stdout();

    if (volume <= 0.0) {
        try stdout.writeAll("vol -inf dB\n");
        return;
    }

    const db = 20.0 * @log(volume) / @log(10.0);
    var line_buf: [32]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buf, "vol {d:.1} dB\n", .{db});
    try stdout.writeAll(line);
}

fn printUnavailable() !void {
    var stdout = std.fs.File.stdout();
    try stdout.writeAll("vol unavailable\n");
}

fn usage() !void {
    var stderr = std.fs.File.stderr();
    try stderr.writeAll("usage: audio-volume up|down|mute|status\n");
}

pub fn main() !u8 {
    var args = std.process.args();
    _ = args.next();
    const action_arg = args.next() orelse {
        try usage();
        return 2;
    };
    const action = parseAction(action_arg) orelse {
        try usage();
        return 2;
    };

    var command_output: [command_output_max]u8 = undefined;
    const sink_name = runCapture(&.{ "pactl", "get-default-sink" }, &command_output) catch {
        try printUnavailable();
        return 0;
    };

    if (sink_name.len == 0) {
        try printUnavailable();
        return 0;
    }

    var sink_name_buf: [512]u8 = undefined;
    if (sink_name.len > sink_name_buf.len) {
        try printUnavailable();
        return 0;
    }
    @memcpy(sink_name_buf[0..sink_name.len], sink_name);
    const stable_sink_name = sink_name_buf[0..sink_name.len];

    if (action == .mute) {
        runWait(&.{ "pactl", "set-sink-mute", stable_sink_name, "toggle" }) catch {
            return 1;
        };
        return 0;
    }

    const nodes = runCapture(&.{ "pw-cli", "ls", "Node" }, &command_output) catch {
        try printUnavailable();
        return 0;
    };
    const node_id = findSinkNodeId(nodes, stable_sink_name) orelse {
        try printUnavailable();
        return 0;
    };

    var node_id_buf: [16]u8 = undefined;
    const node_id_arg = try std.fmt.bufPrint(&node_id_buf, "{d}", .{node_id});
    const props = runCapture(&.{ "pw-cli", "enum-params", node_id_arg, "Props" }, &command_output) catch {
        try printUnavailable();
        return 0;
    };
    const state = parseSinkState(props) orelse {
        try printUnavailable();
        return 0;
    };

    switch (action) {
        .up, .down => {
            const next = volumeAfterStep(state.effectiveVolume(), action);
            setNodeVolume(node_id, next, state.channel_count) catch {
                return 1;
            };
        },
        .status => {
            const mute_output = runCapture(&.{ "pactl", "get-sink-mute", stable_sink_name }, &command_output) catch "";
            if (isMuted(mute_output)) {
                var stdout = std.fs.File.stdout();
                try stdout.writeAll("muted\n");
            } else {
                try printStatus(state.effectiveVolume());
            }
        },
        .mute => unreachable,
    }

    return 0;
}
