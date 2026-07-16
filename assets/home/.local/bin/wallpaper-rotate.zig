const std = @import("std");

const max_path_len = std.fs.max_path_bytes;
const max_spawn_args = 16;

const rotate_interval_ns = 60 * 60 * std.time.ns_per_s;
const daemon_ready_attempts = 50;
const daemon_ready_sleep_ns = 100 * std.time.ns_per_ms;
const video_stop_attempts = 20;
const video_stop_sleep_ns = 100 * std.time.ns_per_ms;

const MediaKind = enum {
    image,
    video,
};

const Wallpaper = struct {
    path_buf: [max_path_len]u8 = undefined,
    path_len: usize = 0,
    kind: MediaKind = .image,

    fn path(self: *const Wallpaper) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    fn set(self: *Wallpaper, new_path: []const u8, kind: MediaKind) !void {
        if (new_path.len > self.path_buf.len) {
            return error.NameTooLong;
        }

        @memcpy(self.path_buf[0..new_path.len], new_path);
        self.path_len = new_path.len;
        self.kind = kind;
    }
};

const EnvOverride = struct {
    runtime_arg_buf: [max_path_len + "XDG_RUNTIME_DIR=".len]u8 = undefined,
    runtime_arg_len: usize = 0,
    display_arg_buf: [max_path_len + "WAYLAND_DISPLAY=".len]u8 = undefined,
    display_arg_len: usize = 0,

    fn enabled(self: *const EnvOverride) bool {
        return self.runtime_arg_len > 0 and self.display_arg_len > 0;
    }

    fn runtimeArg(self: *const EnvOverride) []const u8 {
        return self.runtime_arg_buf[0..self.runtime_arg_len];
    }

    fn displayArg(self: *const EnvOverride) []const u8 {
        return self.display_arg_buf[0..self.display_arg_len];
    }
};

fn envValue(name: []const u8) ?[]const u8 {
    if (std.posix.getenv(name)) |value| {
        return value[0..];
    }

    return null;
}

fn copyInto(dest: []u8, value: []const u8) ![]const u8 {
    if (value.len > dest.len) {
        return error.NameTooLong;
    }

    @memcpy(dest[0..value.len], value);
    return dest[0..value.len];
}

fn pathJoinInto(dest: []u8, dir: []const u8, name: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, dir, "/")) {
        return std.fmt.bufPrint(dest, "{s}{s}", .{ dir, name });
    }

    return std.fmt.bufPrint(dest, "{s}/{s}", .{ dir, name });
}

fn defaultWallpaperDir(dest: []u8) ![]const u8 {
    const home = envValue("HOME") orelse return error.HomeNotSet;
    return pathJoinInto(dest, home, "backgrounds");
}

fn mediaKind(path: []const u8) ?MediaKind {
    const ext = std.fs.path.extension(path);

    if (std.ascii.eqlIgnoreCase(ext, ".jpg") or
        std.ascii.eqlIgnoreCase(ext, ".jpeg") or
        std.ascii.eqlIgnoreCase(ext, ".png") or
        std.ascii.eqlIgnoreCase(ext, ".webp"))
    {
        return .image;
    }

    if (std.ascii.eqlIgnoreCase(ext, ".gif") or
        std.ascii.eqlIgnoreCase(ext, ".mp4") or
        std.ascii.eqlIgnoreCase(ext, ".m4v") or
        std.ascii.eqlIgnoreCase(ext, ".mkv") or
        std.ascii.eqlIgnoreCase(ext, ".mov") or
        std.ascii.eqlIgnoreCase(ext, ".webm") or
        std.ascii.eqlIgnoreCase(ext, ".avi"))
    {
        return .video;
    }

    return null;
}

fn buildSpawnArgv(env: *const EnvOverride, argv: []const []const u8, out: *[max_spawn_args][]const u8) ![]const []const u8 {
    var len: usize = 0;

    if (env.enabled()) {
        out[len] = "env";
        len += 1;
        out[len] = env.runtimeArg();
        len += 1;
        out[len] = env.displayArg();
        len += 1;
    }

    if (len + argv.len > out.len) {
        return error.TooManyArguments;
    }

    for (argv) |arg| {
        out[len] = arg;
        len += 1;
    }

    return out[0..len];
}

fn runWait(env: *const EnvOverride, argv: []const []const u8, ignore_output: bool) !bool {
    var argv_storage: [max_spawn_args][]const u8 = undefined;
    const spawn_argv = try buildSpawnArgv(env, argv, &argv_storage);

    var child = std.process.Child.init(spawn_argv, std.heap.page_allocator);
    child.stdin_behavior = .Ignore;
    if (ignore_output) {
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
    } else {
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
    }

    child.spawn() catch |err| switch (err) {
        error.FileNotFound => {
            return false;
        },
        else => {
            return err;
        },
    };

    const term = try child.wait();
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn spawnDetached(env: *const EnvOverride, argv: []const []const u8) !?std.posix.pid_t {
    var argv_storage: [max_spawn_args][]const u8 = undefined;
    const spawn_argv = try buildSpawnArgv(env, argv, &argv_storage);

    var child = std.process.Child.init(spawn_argv, std.heap.page_allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.pgid = 0;

    child.spawn() catch |err| switch (err) {
        error.FileNotFound => {
            return null;
        },
        else => {
            return err;
        },
    };

    return child.id;
}

fn ensureWaylandDisplay() !EnvOverride {
    var env: EnvOverride = .{};

    if (envValue("WAYLAND_DISPLAY") != null) {
        return env;
    }

    var runtime_buf: [max_path_len]u8 = undefined;
    const runtime_dir = blk: {
        if (envValue("XDG_RUNTIME_DIR")) |value| {
            break :blk value;
        }

        break :blk try std.fmt.bufPrint(&runtime_buf, "/run/user/{d}", .{std.os.linux.getuid()});
    };

    var dir = try std.fs.cwd().openDir(runtime_dir, .{ .iterate = true });
    defer dir.close();

    var display_buf: [max_path_len]u8 = undefined;
    var display_len: usize = 0;

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "wayland-")) {
            continue;
        }

        const current = display_buf[0..display_len];
        if (display_len == 0 or std.mem.order(u8, entry.name, current) == .gt) {
            const copied = try copyInto(&display_buf, entry.name);
            display_len = copied.len;
        }
    }

    if (display_len == 0) {
        return error.WaylandDisplayNotFound;
    }

    const runtime_arg = try std.fmt.bufPrint(&env.runtime_arg_buf, "XDG_RUNTIME_DIR={s}", .{runtime_dir});
    const display_arg = try std.fmt.bufPrint(&env.display_arg_buf, "WAYLAND_DISPLAY={s}", .{display_buf[0..display_len]});
    env.runtime_arg_len = runtime_arg.len;
    env.display_arg_len = display_arg.len;

    return env;
}

fn startDaemon(env: *const EnvOverride) !void {
    if (try runWait(env, &.{ "awww", "query" }, true)) {
        return;
    }

    _ = try spawnDetached(env, &.{"awww-daemon"});
    for (0..daemon_ready_attempts) |_| {
        if (try runWait(env, &.{ "awww", "query" }, true)) {
            return;
        }

        std.Thread.sleep(daemon_ready_sleep_ns);
    }

    return error.AwwwDaemonNotReady;
}

fn processAlive(pid: std.posix.pid_t) bool {
    std.posix.kill(pid, 0) catch {
        return false;
    };

    return true;
}

fn stopVideoWallpaper(video_pid: *?std.posix.pid_t) void {
    const pid = video_pid.* orelse {
        return;
    };
    video_pid.* = null;

    std.posix.kill(-pid, std.os.linux.SIG.TERM) catch {};
    for (0..video_stop_attempts) |_| {
        if (!processAlive(pid)) {
            return;
        }

        std.Thread.sleep(video_stop_sleep_ns);
    }

    std.posix.kill(-pid, std.os.linux.SIG.KILL) catch {};
}

fn startVideoWallpaper(env: *const EnvOverride, video_pid: *?std.posix.pid_t, path: []const u8) !void {
    stopVideoWallpaper(video_pid);

    video_pid.* = try spawnDetached(env, &.{
        "mpvpaper",
        "-o",
        "no-audio loop-file=inf hwdec=auto",
        "ALL",
        path,
    }) orelse {
        std.log.warn("mpvpaper is required for video wallpaper: {s}", .{path});
        return;
    };
}

fn pickWallpaper(rng: std.Random, wallpaper_dir: []const u8, last: ?[]const u8) !?Wallpaper {
    var dir = std.fs.cwd().openDir(wallpaper_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try std.fs.cwd().makePath(wallpaper_dir);
            return null;
        },
        else => {
            return err;
        },
    };
    defer dir.close();

    var chosen: ?Wallpaper = null;
    var seen: u64 = 0;

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) {
            continue;
        }

        const kind = mediaKind(entry.name) orelse {
            continue;
        };

        const stat = dir.statFile(entry.name) catch {
            continue;
        };
        if (stat.size == 0) {
            continue;
        }

        var candidate_path_buf: [max_path_len]u8 = undefined;
        const candidate_path = try pathJoinInto(&candidate_path_buf, wallpaper_dir, entry.name);
        if (last) |last_path| {
            if (std.mem.eql(u8, candidate_path, last_path)) {
                continue;
            }
        }

        seen += 1;
        if (rng.uintLessThan(u64, seen) == 0) {
            var next: Wallpaper = .{};
            try next.set(candidate_path, kind);
            chosen = next;
        }
    }

    return chosen;
}

pub fn main() !void {
    var args = std.process.args();
    _ = args.skip();

    var wallpaper_dir_buf: [max_path_len]u8 = undefined;
    const wallpaper_dir = blk: {
        if (args.next()) |arg| {
            break :blk try copyInto(&wallpaper_dir_buf, arg);
        }

        break :blk try defaultWallpaperDir(&wallpaper_dir_buf);
    };

    const child_env = try ensureWaylandDisplay();

    var seed: u64 = @intCast(std.time.nanoTimestamp());
    std.posix.getrandom(std.mem.asBytes(&seed)) catch {};
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var last_wallpaper: ?Wallpaper = null;
    var video_pid: ?std.posix.pid_t = null;
    defer stopVideoWallpaper(&video_pid);

    while (true) {
        const last_path = blk: {
            if (last_wallpaper) |*wallpaper| {
                break :blk wallpaper.path();
            }

            break :blk null;
        };

        if (try pickWallpaper(rng, wallpaper_dir, last_path)) |choice| {
            switch (choice.kind) {
                .image => {
                    stopVideoWallpaper(&video_pid);
                    try startDaemon(&child_env);
                    _ = try runWait(&child_env, &.{ "awww", "img", choice.path() }, false);
                },
                .video => {
                    try startVideoWallpaper(&child_env, &video_pid, choice.path());
                },
            }

            last_wallpaper = choice;
        }

        std.Thread.sleep(rotate_interval_ns);
    }
}
