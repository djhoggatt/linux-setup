const std = @import("std");

/// Maximum text lengths for each rendered status segment.
const audio_max_len = 32;
const network_max_len = 96;
const clock_max_len = 64;

/// Enough space for "<network> | <audio> | <clock>\n".
const line_max_len = network_max_len + audio_max_len + clock_max_len + 7;

/// Trim leading and trailing ASCII whitespace from command output.
fn trimAscii(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, &std.ascii.whitespace);
}

/// Run a short-lived command and capture stdout into a caller-owned buffer.
/// This keeps the hot path allocation-free while still letting us reuse small
/// system tools such as `pactl`, `nmcli`, and `date`.
fn runCommandCapture(argv: []const []const u8, out: []u8) ![]const u8 {
    var child_storage: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&child_storage);

    var child = std.process.Child.init(argv, fba.allocator());
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();
    const stdout = child.stdout.?;
    const n = try stdout.readAll(out);
    _ = try child.wait();
    return trimAscii(out[0..n]);
}

/// Extract the first percentage token from pactl output, for example "35%".
fn parsePercent(bytes: []const u8) ?u8 {
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (!std.ascii.isDigit(bytes[i])) continue;

        var j = i;
        while (j < bytes.len and std.ascii.isDigit(bytes[j])) : (j += 1) {}
        if (j < bytes.len and bytes[j] == '%') {
            return std.fmt.parseInt(u8, bytes[i..j], 10) catch null;
        }
    }
    return null;
}

/// Audio changes are event-driven. This source keeps `pactl subscribe` open as
/// a wakeup fd and rebuilds its visible text when PipeWire/Pulse audio state
/// changes.
const AudioSource = struct {
    child_storage: [16384]u8 = undefined,
    fba: std.heap.FixedBufferAllocator = undefined,
    child: ?std.process.Child = null,
    text: [audio_max_len]u8 = undefined,
    text_len: usize = 0,
    scratch: [512]u8 = undefined,

    /// Start the monitor child and populate the initial audio text.
    fn init(self: *AudioSource) !void {
        self.fba = std.heap.FixedBufferAllocator.init(&self.child_storage);
        try self.spawnMonitor();
        _ = try self.refresh();
    }

    /// Return the fd to wait on in poll(2).
    fn fd(self: *AudioSource) std.posix.fd_t {
        if (self.child) |*child| {
            if (child.stdout) |file| return file.handle;
        }
        return -1;
    }

    /// Return the current rendered text for this source.
    fn slice(self: *const AudioSource) []const u8 {
        return self.text[0..self.text_len];
    }

    /// Spawn `pactl subscribe`, which is used only as an event stream.
    fn spawnMonitor(self: *AudioSource) !void {
        self.fba = std.heap.FixedBufferAllocator.init(&self.child_storage);
        var child = std.process.Child.init(&.{ "/usr/bin/pactl", "subscribe" }, self.fba.allocator());
        child.stdin_behavior = .Close;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        self.child = child;
    }

    /// Recompute the audio text from current sink mute/volume state.
    fn refresh(self: *AudioSource) !bool {
        const mute = try runCommandCapture(
            &.{ "/usr/bin/pactl", "get-sink-mute", "@DEFAULT_SINK@" },
            self.scratch[0..256],
        );

        if (std.mem.indexOf(u8, mute, "yes") != null) {
            if (std.mem.eql(u8, self.slice(), "muted")) return false;
            self.text_len = "muted".len;
            @memcpy(self.text[0.."muted".len], "muted");
            return true;
        }

        const volume = try runCommandCapture(
            &.{ "/usr/bin/pactl", "get-sink-volume", "@DEFAULT_SINK@" },
            self.scratch[0..],
        );
        const percent = parsePercent(volume) orelse 0;
        var next_buf: [audio_max_len]u8 = undefined;
        const next = try std.fmt.bufPrint(&next_buf, "vol {d}%", .{percent});

        if (std.mem.eql(u8, self.slice(), next)) return false;
        self.text_len = next.len;
        @memcpy(self.text[0..next.len], next);
        return true;
    }

    /// Drain the event fd and refresh the source text. If the monitor child
    /// exits, recreate it transparently and keep going.
    fn onReadable(self: *AudioSource) !bool {
        const child = if (self.child) |*child| child else return self.refresh() catch false;
        const file = if (child.stdout) |file| file else return self.refresh() catch false;

        var discard: [256]u8 = undefined;
        const n = file.read(&discard) catch 0;
        if (n == 0) {
            _ = child.wait() catch {};
            self.child = null;
            try self.spawnMonitor();
        }

        return self.refresh() catch false;
    }
};

/// Network changes are also event-driven. `nmcli monitor` provides a wakeup fd,
/// while `nmcli dev status` provides the deterministic snapshot we actually
/// render.
const NetworkSource = struct {
    child_storage: [16384]u8 = undefined,
    fba: std.heap.FixedBufferAllocator = undefined,
    child: ?std.process.Child = null,
    text: [network_max_len]u8 = undefined,
    text_len: usize = 0,
    scratch: [2048]u8 = undefined,

    /// Start the monitor child and populate the initial network text.
    fn init(self: *NetworkSource) !void {
        self.fba = std.heap.FixedBufferAllocator.init(&self.child_storage);
        try self.spawnMonitor();
        _ = try self.refresh();
    }

    /// Return the fd to wait on in poll(2).
    fn fd(self: *NetworkSource) std.posix.fd_t {
        if (self.child) |*child| {
            if (child.stdout) |file| return file.handle;
        }
        return -1;
    }

    /// Return the current rendered text for this source.
    fn slice(self: *const NetworkSource) []const u8 {
        return self.text[0..self.text_len];
    }

    /// Spawn `nmcli monitor`, which is used only as an event stream.
    fn spawnMonitor(self: *NetworkSource) !void {
        self.fba = std.heap.FixedBufferAllocator.init(&self.child_storage);
        var child = std.process.Child.init(&.{ "/usr/bin/nmcli", "monitor" }, self.fba.allocator());
        child.stdin_behavior = .Close;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        self.child = child;
    }

    /// Recompute the network text from current device state.
    fn refresh(self: *NetworkSource) !bool {
        const out = try runCommandCapture(
            &.{ "/usr/bin/nmcli", "-t", "-f", "TYPE,STATE,CONNECTION", "dev", "status" },
            self.scratch[0..],
        );

        var next_buf: [network_max_len]u8 = undefined;
        var next: []const u8 = "offline";

        var lines = std.mem.tokenizeScalar(u8, out, '\n');
        while (lines.next()) |line| {
            var parts = std.mem.splitScalar(u8, line, ':');
            const dev_type = parts.next() orelse continue;
            const state = parts.next() orelse continue;
            const connection = parts.next() orelse "";

            if (std.mem.eql(u8, dev_type, "wifi") and std.mem.eql(u8, state, "connected")) {
                next = try std.fmt.bufPrint(&next_buf, "wifi {s}", .{connection});
                break;
            }
        }

        if (std.mem.eql(u8, next, "offline")) {
            lines = std.mem.tokenizeScalar(u8, out, '\n');
            while (lines.next()) |line| {
                var parts = std.mem.splitScalar(u8, line, ':');
                const dev_type = parts.next() orelse continue;
                const state = parts.next() orelse continue;

                if (std.mem.eql(u8, dev_type, "ethernet") and std.mem.eql(u8, state, "connected")) {
                    next = "wired";
                    break;
                }
            }
        }

        if (std.mem.eql(u8, self.slice(), next)) return false;
        self.text_len = next.len;
        @memcpy(self.text[0..next.len], next);
        return true;
    }

    /// Drain the event fd and refresh the source text. If the monitor child
    /// exits, recreate it transparently and keep going.
    fn onReadable(self: *NetworkSource) !bool {
        const child = if (self.child) |*child| child else return self.refresh() catch false;
        const file = if (child.stdout) |file| file else return self.refresh() catch false;

        var discard: [256]u8 = undefined;
        const n = file.read(&discard) catch 0;
        if (n == 0) {
            _ = child.wait() catch {};
            self.child = null;
            try self.spawnMonitor();
        }

        return self.refresh() catch false;
    }
};

/// The clock source wakes only at minute boundaries via timerfd instead of
/// polling wall-clock time in a loop.
const ClockSource = struct {
    fd_: std.posix.fd_t = -1,
    text: [clock_max_len]u8 = undefined,
    text_len: usize = 0,
    scratch: [128]u8 = undefined,

    /// Create the timerfd, arm it, and populate the initial clock text.
    fn init(self: *ClockSource) !void {
        self.fd_ = try std.posix.timerfd_create(.REALTIME, .{ .CLOEXEC = true, .NONBLOCK = true });
        try self.arm();
        _ = try self.refresh();
    }

    /// Return the fd to wait on in poll(2).
    fn fd(self: *ClockSource) std.posix.fd_t {
        return self.fd_;
    }

    /// Return the current rendered text for this source.
    fn slice(self: *const ClockSource) []const u8 {
        return self.text[0..self.text_len];
    }

    /// Arm the timer to the next minute boundary, then every 60 seconds after.
    fn arm(self: *ClockSource) !void {
        const now = std.time.timestamp();
        const next = 60 - @mod(now, 60);
        const spec = std.os.linux.itimerspec{
            .it_interval = .{ .sec = 60, .nsec = 0 },
            .it_value = .{ .sec = next, .nsec = 0 },
        };
        try std.posix.timerfd_settime(self.fd_, .{}, &spec, null);
    }

    /// Recompute the visible clock text.
    fn refresh(self: *ClockSource) !bool {
        const out = try runCommandCapture(
            &.{ "/usr/bin/date", "+%a %Y-%m-%d %H:%M" },
            self.scratch[0..],
        );

        if (std.mem.eql(u8, self.slice(), out)) return false;
        self.text_len = out.len;
        @memcpy(self.text[0..out.len], out);
        return true;
    }

    /// Drain timerfd expirations and refresh the clock text.
    fn onReadable(self: *ClockSource) !bool {
        var expirations: [8]u8 = undefined;
        _ = std.posix.read(self.fd_, &expirations) catch 0;
        return self.refresh();
    }
};

/// Adding a new status item means adding a new variant here plus its source
/// implementation above. The main poll loop can stay the same.
const Source = union(enum) {
    audio: AudioSource,
    network: NetworkSource,
    clock: ClockSource,

    /// Initialize the concrete source behind this union.
    fn init(self: *Source) !void {
        switch (self.*) {
            .audio => |*audio| try audio.init(),
            .network => |*network| try network.init(),
            .clock => |*clock| try clock.init(),
        }
    }

    /// Return the fd to wait on in poll(2).
    fn fd(self: *Source) std.posix.fd_t {
        return switch (self.*) {
            .audio => |*audio| audio.fd(),
            .network => |*network| network.fd(),
            .clock => |*clock| clock.fd(),
        };
    }

    /// Return the current rendered text for this source.
    fn slice(self: *const Source) []const u8 {
        return switch (self.*) {
            .audio => |*audio| audio.slice(),
            .network => |*network| network.slice(),
            .clock => |*clock| clock.slice(),
        };
    }

    /// Handle readability or error/hup on the underlying fd.
    fn onReadable(self: *Source) bool {
        return switch (self.*) {
            .audio => |*audio| audio.onReadable() catch false,
            .network => |*network| network.onReadable() catch false,
            .clock => |*clock| clock.onReadable() catch false,
        };
    }
};

/// Render the final bar line from the individual source texts.
fn renderLine(sources: []const Source, out: []u8) ![]const u8 {
    return std.fmt.bufPrint(
        out,
        "{s} | {s} | {s}\n",
        .{ sources[1].slice(), sources[0].slice(), sources[2].slice() },
    );
}

pub fn main() !void {
    var stdout = std.fs.File.stdout();

    var sources = [_]Source{
        .{ .audio = .{} },
        .{ .network = .{} },
        .{ .clock = .{} },
    };

    for (&sources) |*source| {
        try source.init();
    }

    var line_buf: [line_max_len]u8 = undefined;
    try stdout.writeAll(try renderLine(&sources, &line_buf));

    while (true) {
        // Rebuild pollfds from the current sources each iteration so a source
        // can transparently recreate its child process/fd after EOF.
        var pollfds = [_]std.posix.pollfd{
            .{ .fd = sources[0].fd(), .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = sources[1].fd(), .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = sources[2].fd(), .events = std.posix.POLL.IN, .revents = 0 },
        };

        _ = try std.posix.poll(&pollfds, -1);

        var changed = false;
        for (pollfds, 0..) |pfd, i| {
            if ((pfd.revents & std.posix.POLL.IN) != 0) {
                changed = sources[i].onReadable() or changed;
            } else if ((pfd.revents & (std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0) {
                changed = sources[i].onReadable() or changed;
            }
        }

        if (changed) {
            try stdout.writeAll(try renderLine(&sources, &line_buf));
        }
    }
}
