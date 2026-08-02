const std = @import("std");

const child_allocator_storage_max = 16 * 1024;

const CommandResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    code: u8,

    fn ok(self: CommandResult) bool {
        return self.code == 0;
    }
};

fn trimTrailingNewline(bytes: []const u8) []const u8 {
    var end = bytes.len;
    while (end > 0 and (bytes[end - 1] == '\n' or bytes[end - 1] == '\r')) {
        end -= 1;
    }
    return bytes[0..end];
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
    var allocator = std.heap.FixedBufferAllocator.init(&child_storage);
    var child = std.process.Child.init(argv, allocator.allocator());
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

    const stdout_len = try child.stdout.?.readAll(stdout_buf);
    const stderr_len = try child.stderr.?.readAll(stderr_buf);
    const term = try child.wait();
    return .{
        .stdout = trimTrailingNewline(stdout_buf[0..stdout_len]),
        .stderr = trimTrailingNewline(stderr_buf[0..stderr_len]),
        .code = commandTermCode(term),
    };
}

pub fn main() void {
    const choices = "Lock screen\nSuspend\nHibernate\nLog out\nRestart\nPower off\n";
    var stdout_buf: [64]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    const selection = runCapture(
        &.{ "rofi", "-dmenu", "-i", "-p", "Power" },
        choices,
        &stdout_buf,
        &stderr_buf,
    ) catch |err| {
        std.debug.print("waybar-power-menu: {s}\n", .{@errorName(err)});
        return;
    };
    if (!selection.ok()) return;

    const command: []const []const u8 = if (std.mem.eql(u8, selection.stdout, "Lock screen"))
        &.{ "lock-screen" }
    else if (std.mem.eql(u8, selection.stdout, "Suspend"))
        &.{ "systemctl", "suspend" }
    else if (std.mem.eql(u8, selection.stdout, "Hibernate"))
        &.{ "systemctl", "hibernate" }
    else if (std.mem.eql(u8, selection.stdout, "Log out"))
        &.{ "swaymsg", "exit" }
    else if (std.mem.eql(u8, selection.stdout, "Restart"))
        &.{ "systemctl", "reboot" }
    else if (std.mem.eql(u8, selection.stdout, "Power off"))
        &.{ "systemctl", "poweroff" }
    else
        return;

    const action = runCapture(command, null, &stdout_buf, &stderr_buf) catch |err| {
        std.debug.print("waybar-power-menu: {s}\n", .{@errorName(err)});
        return;
    };
    if (!action.ok()) {
        std.debug.print("waybar-power-menu: {s}\n", .{action.stderr});
    }
}
