const std = @import("std");

const command_stdout_max = 256 * 1024;
const command_stderr_max = 16 * 1024;
const child_allocator_storage_max = 16 * 1024;
const max_sinks = 32;
const id_max_len = 16;
const name_max_len = 192;
const volume_max_len = 24;
const label_max_len = 320;
const node_name_max_len = 192;
const stream_id_max_len = 16;
const menu_input_max = max_sinks * (label_max_len + 1);

const CommandResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    code: u8,

    fn ok(self: CommandResult) bool {
        return self.code == 0;
    }
};

const Sink = struct {
    id_buf: [id_max_len]u8 = undefined,
    id_len: usize = 0,
    name_buf: [name_max_len]u8 = undefined,
    name_len: usize = 0,
    volume_buf: [volume_max_len]u8 = undefined,
    volume_len: usize = 0,
    label_buf: [label_max_len]u8 = undefined,
    label_len: usize = 0,
    active: bool = false,

    fn id(self: *const Sink) []const u8 {
        return self.id_buf[0..self.id_len];
    }

    fn name(self: *const Sink) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    fn volume(self: *const Sink) []const u8 {
        return self.volume_buf[0..self.volume_len];
    }

    fn label(self: *const Sink) []const u8 {
        return self.label_buf[0..self.label_len];
    }

    fn set(self: *Sink, new_id: []const u8, new_name: []const u8, new_volume: []const u8, active: bool) !void {
        self.id_len = try copyInto(&self.id_buf, new_id);
        self.name_len = try copyInto(&self.name_buf, new_name);
        self.volume_len = try copyVolumeLabel(&self.volume_buf, new_volume);
        self.active = active;
    }

    fn buildLabel(self: *Sink, duplicate_name: bool) !void {
        const marker: []const u8 = if (self.active) "*" else "o";
        const rendered = if (duplicate_name)
            try std.fmt.bufPrint(&self.label_buf, "{s}  {s}    {s}    id:{s}", .{
                marker,
                self.name(),
                self.volume(),
                self.id(),
            })
        else
            try std.fmt.bufPrint(&self.label_buf, "{s}  {s}    {s}", .{
                marker,
                self.name(),
                self.volume(),
            });
        self.label_len = rendered.len;
    }
};

fn trimAscii(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, &std.ascii.whitespace);
}

fn trimTrailingNewline(bytes: []const u8) []const u8 {
    var end = bytes.len;
    while (end > 0 and (bytes[end - 1] == '\n' or bytes[end - 1] == '\r')) {
        end -= 1;
    }
    return bytes[0..end];
}

fn copyInto(dest: []u8, value: []const u8) !usize {
    if (value.len > dest.len) {
        return error.FieldTooLong;
    }

    @memcpy(dest[0..value.len], value);
    return value.len;
}

fn copyVolumeLabel(dest: []u8, value: []const u8) !usize {
    const trimmed = trimAscii(value);
    if (std.fmt.parseFloat(f64, trimmed)) |volume| {
        const percent: i64 = @intFromFloat(@round(volume * 100.0));
        const label = try std.fmt.bufPrint(dest, "{d}%", .{percent});
        return label.len;
    } else |_| {
        return copyInto(dest, trimmed);
    }
}

fn appendBytes(dest: []u8, len: *usize, value: []const u8) !void {
    if (len.* + value.len > dest.len) {
        return error.BufferTooSmall;
    }

    @memcpy(dest[len.* .. len.* + value.len], value);
    len.* += value.len;
}

fn commandTermCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .Exited => |code| code,
        else => 255,
    };
}

fn runCapture(
    argv: []const []const u8,
    stdin_text: ?[]const u8,
    stdout_buf: []u8,
    stderr_buf: []u8,
) !CommandResult {
    var child_storage: [child_allocator_storage_max]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&child_storage);

    var child = std.process.Child.init(argv, fba.allocator());
    child.stdin_behavior = if (stdin_text == null) .Close else .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    if (stdin_text) |input| {
        const stdin = child.stdin.?;
        try stdin.writeAll(input);
        stdin.close();
        child.stdin = null;
    }

    const stdout = child.stdout.?;
    const stderr = child.stderr.?;
    const stdout_len = try stdout.readAll(stdout_buf);
    const stderr_len = try stderr.readAll(stderr_buf);
    const term = try child.wait();

    return .{
        .stdout = trimTrailingNewline(stdout_buf[0..stdout_len]),
        .stderr = trimTrailingNewline(stderr_buf[0..stderr_len]),
        .code = commandTermCode(term),
    };
}

fn runChecked(argv: []const []const u8) !void {
    var stdout_buf: [1024]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    const result = try runCapture(argv, null, &stdout_buf, &stderr_buf);
    if (!result.ok()) {
        return error.CommandFailed;
    }
}

fn rofiError(message: []const u8) void {
    var stdout_buf: [128]u8 = undefined;
    var stderr_buf: [128]u8 = undefined;
    _ = runCapture(&.{ "rofi", "-e", message }, null, &stdout_buf, &stderr_buf) catch {};
}

fn parseSinkLine(line: []const u8, sink: *Sink) !bool {
    const volume_start = std.mem.indexOf(u8, line, "[vol:") orelse return false;
    const before_volume = line[0..volume_start];

    var id_start: ?usize = null;
    var id_end: usize = 0;
    var i: usize = 0;
    while (i < before_volume.len) : (i += 1) {
        if (!std.ascii.isDigit(before_volume[i])) {
            continue;
        }

        var j = i + 1;
        while (j < before_volume.len and std.ascii.isDigit(before_volume[j])) : (j += 1) {}
        if (j < before_volume.len and before_volume[j] == '.') {
            id_start = i;
            id_end = j;
            break;
        }
        i = j;
    }

    const start = id_start orelse return false;
    const name = trimAscii(before_volume[id_end + 1 ..]);
    if (name.len == 0) {
        return false;
    }

    const volume_text_start = volume_start + "[vol:".len;
    const volume_rest = line[volume_text_start..];
    const volume_text_end = std.mem.indexOfScalar(u8, volume_rest, ']') orelse volume_rest.len;

    try sink.set(
        before_volume[start..id_end],
        name,
        volume_rest[0..volume_text_end],
        std.mem.indexOfScalar(u8, before_volume[0..start], '*') != null,
    );
    return true;
}

fn collectSinks(status: []const u8, sinks: *[max_sinks]Sink) !usize {
    var count: usize = 0;
    var in_sinks = false;
    var lines = std.mem.splitScalar(u8, status, '\n');

    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "Sinks:") != null) {
            in_sinks = true;
            continue;
        }
        if (in_sinks and std.mem.indexOf(u8, line, "Sources:") != null) {
            break;
        }
        if (!in_sinks) {
            continue;
        }

        if (count == sinks.len) {
            return error.TooManySinks;
        }

        var sink: Sink = .{};
        if (try parseSinkLine(line, &sink)) {
            sinks[count] = sink;
            count += 1;
        }
    }

    for (sinks[0..count], 0..) |*sink, index| {
        var duplicate_name = false;
        for (sinks[0..count], 0..) |*other, other_index| {
            if (index == other_index) {
                continue;
            }
            if (std.mem.eql(u8, sink.name(), other.name())) {
                duplicate_name = true;
                break;
            }
        }
        try sink.buildLabel(duplicate_name);
    }

    return count;
}

fn chooseSink(sinks: []const Sink) !?usize {
    var menu_input: [menu_input_max]u8 = undefined;
    var menu_len: usize = 0;

    for (sinks) |*sink| {
        try appendBytes(&menu_input, &menu_len, sink.label());
        try appendBytes(&menu_input, &menu_len, "\n");
    }

    var stdout_buf: [label_max_len + 8]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    const selection = try runCapture(
        &.{ "rofi", "-dmenu", "-i", "-p", "Audio Output" },
        menu_input[0..menu_len],
        &stdout_buf,
        &stderr_buf,
    );
    if (!selection.ok()) {
        return null;
    }

    const selected = trimAscii(selection.stdout);
    for (sinks, 0..) |*sink, index| {
        if (std.mem.eql(u8, selected, sink.label())) {
            return index;
        }
    }

    return null;
}

fn nodeNameForId(id: []const u8, out: []u8) !?[]const u8 {
    var inspect_buf: [64 * 1024]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    const result = try runCapture(&.{ "wpctl", "inspect", id }, null, &inspect_buf, &stderr_buf);
    if (!result.ok()) {
        return null;
    }

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const prefix = "node.name = \"";
        const start = std.mem.indexOf(u8, line, prefix) orelse continue;
        const value_start = start + prefix.len;
        const value_rest = line[value_start..];
        const value_end = std.mem.indexOfScalar(u8, value_rest, '"') orelse continue;
        const value = value_rest[0..value_end];
        const len = try copyInto(out, value);
        return out[0..len];
    }

    return null;
}

fn moveActiveStreams(target_sink: []const u8) !void {
    var inputs_buf: [64 * 1024]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    const result = try runCapture(&.{ "pactl", "list", "short", "sink-inputs" }, null, &inputs_buf, &stderr_buf);
    if (!result.ok()) {
        return;
    }

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = trimAscii(line);
        if (trimmed.len == 0) {
            continue;
        }

        var end: usize = 0;
        while (end < trimmed.len and !std.ascii.isWhitespace(trimmed[end])) : (end += 1) {}
        if (end == 0 or end > stream_id_max_len) {
            continue;
        }

        runChecked(&.{ "pactl", "move-sink-input", trimmed[0..end], target_sink }) catch {};
    }
}

fn realMain() !u8 {
    var status_buf: [command_stdout_max]u8 = undefined;
    var stderr_buf: [command_stderr_max]u8 = undefined;
    const status = try runCapture(&.{ "wpctl", "status" }, null, &status_buf, &stderr_buf);
    if (!status.ok()) {
        rofiError(if (status.stderr.len > 0) status.stderr else "Could not read audio devices.");
        return 1;
    }

    var sinks: [max_sinks]Sink = undefined;
    const sink_count = try collectSinks(status.stdout, &sinks);
    if (sink_count == 0) {
        rofiError("No audio output devices found.");
        return 1;
    }

    const selected_index = (try chooseSink(sinks[0..sink_count])) orelse return 0;
    const sink = &sinks[selected_index];
    try runChecked(&.{ "wpctl", "set-default", sink.id() });

    var node_name_buf: [node_name_max_len]u8 = undefined;
    if (try nodeNameForId(sink.id(), &node_name_buf)) |node_name| {
        try moveActiveStreams(node_name);
    }

    return 0;
}

pub fn main() void {
    const code = realMain() catch |err| {
        const message = @errorName(err);
        std.debug.print("waybar-audio-menu: {s}\n", .{message});
        rofiError(message);
        std.process.exit(1);
    };
    std.process.exit(code);
}
