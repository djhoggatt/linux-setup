const std = @import("std");

const command_stdout_max = 256 * 1024;
const command_stderr_max = 16 * 1024;
const child_allocator_storage_max = 16 * 1024;
const max_networks = 96;
const field_max_len = 192;
const device_max_len = 64;
const ssid_max_len = 96;
const bssid_max_len = 32;
const security_max_len = 64;
const signal_max_len = 8;
const label_max_len = 320;
const menu_input_max = max_networks * (label_max_len + 1);
const password_max_len = 256;

const CommandResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    code: u8,

    fn ok(self: CommandResult) bool {
        return self.code == 0;
    }
};

const Network = struct {
    ssid_buf: [ssid_max_len]u8 = undefined,
    ssid_len: usize = 0,
    bssid_buf: [bssid_max_len]u8 = undefined,
    bssid_len: usize = 0,
    security_buf: [security_max_len]u8 = undefined,
    security_len: usize = 0,
    signal_buf: [signal_max_len]u8 = undefined,
    signal_len: usize = 0,
    label_buf: [label_max_len]u8 = undefined,
    label_len: usize = 0,
    active: bool = false,

    fn ssid(self: *const Network) []const u8 {
        return self.ssid_buf[0..self.ssid_len];
    }

    fn bssid(self: *const Network) []const u8 {
        return self.bssid_buf[0..self.bssid_len];
    }

    fn security(self: *const Network) []const u8 {
        return self.security_buf[0..self.security_len];
    }

    fn signal(self: *const Network) []const u8 {
        return self.signal_buf[0..self.signal_len];
    }

    fn label(self: *const Network) []const u8 {
        return self.label_buf[0..self.label_len];
    }

    fn set(
        self: *Network,
        active: bool,
        new_ssid: []const u8,
        new_bssid: []const u8,
        new_security: []const u8,
        new_signal: []const u8,
    ) !void {
        self.active = active;
        self.ssid_len = try copyInto(&self.ssid_buf, trimAscii(new_ssid));
        self.bssid_len = try copyInto(&self.bssid_buf, trimAscii(new_bssid));
        self.security_len = try copyInto(&self.security_buf, trimAscii(new_security));
        self.signal_len = try copyInto(&self.signal_buf, trimAscii(new_signal));
    }

    fn buildLabel(self: *Network, duplicate_ssid: bool) !void {
        const marker: []const u8 = if (self.active) "*" else "o";
        const security_text = if (self.security_len == 0) "open" else self.security();
        const rendered = if (duplicate_ssid and self.bssid_len > 0)
            try std.fmt.bufPrint(&self.label_buf, "{s}  {s}    {s}    {s}%    {s}", .{
                marker,
                self.ssid(),
                security_text,
                self.signal(),
                self.bssid(),
            })
        else
            try std.fmt.bufPrint(&self.label_buf, "{s}  {s}    {s}    {s}%", .{
                marker,
                self.ssid(),
                security_text,
                self.signal(),
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

fn rofiError(message: []const u8) void {
    var stdout_buf: [128]u8 = undefined;
    var stderr_buf: [128]u8 = undefined;
    _ = runCapture(&.{ "rofi", "-e", message }, null, &stdout_buf, &stderr_buf) catch {};
}

fn readNmcliField(line: []const u8, index: *usize, dest: []u8) ![]const u8 {
    var len: usize = 0;
    var escaped = false;

    while (index.* < line.len) : (index.* += 1) {
        const byte = line[index.*];
        if (escaped) {
            if (len == dest.len) {
                return error.FieldTooLong;
            }
            dest[len] = byte;
            len += 1;
            escaped = false;
            continue;
        }

        if (byte == '\\') {
            escaped = true;
            continue;
        }

        if (byte == ':') {
            index.* += 1;
            return dest[0..len];
        }

        if (len == dest.len) {
            return error.FieldTooLong;
        }
        dest[len] = byte;
        len += 1;
    }

    if (escaped) {
        if (len == dest.len) {
            return error.FieldTooLong;
        }
        dest[len] = '\\';
        len += 1;
    }

    return dest[0..len];
}

fn wifiDevice(out: []u8) !?[]const u8 {
    var stdout_buf: [32 * 1024]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    const result = try runCapture(
        &.{ "nmcli", "-t", "-f", "DEVICE,TYPE,STATE", "device", "status" },
        null,
        &stdout_buf,
        &stderr_buf,
    );
    if (!result.ok()) {
        return null;
    }

    var fallback_buf: [device_max_len]u8 = undefined;
    var fallback_len: usize = 0;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        var index: usize = 0;
        var device_buf: [field_max_len]u8 = undefined;
        var type_buf: [field_max_len]u8 = undefined;
        var state_buf: [field_max_len]u8 = undefined;
        const device = try readNmcliField(line, &index, &device_buf);
        const device_type = try readNmcliField(line, &index, &type_buf);
        const state = try readNmcliField(line, &index, &state_buf);

        if (!std.mem.eql(u8, device_type, "wifi")) {
            continue;
        }

        if (fallback_len == 0) {
            fallback_len = try copyInto(&fallback_buf, device);
        }
        if (std.mem.startsWith(u8, state, "connected")) {
            const len = try copyInto(out, device);
            return out[0..len];
        }
    }

    if (fallback_len > 0) {
        const len = try copyInto(out, fallback_buf[0..fallback_len]);
        return out[0..len];
    }

    return null;
}

fn networkExists(networks: []const Network, ssid: []const u8, bssid: []const u8) bool {
    for (networks) |*network| {
        if (std.mem.eql(u8, network.ssid(), ssid) and std.mem.eql(u8, network.bssid(), bssid)) {
            return true;
        }
    }
    return false;
}

fn collectNetworks(networks: *[max_networks]Network) !usize {
    var stdout_buf: [command_stdout_max]u8 = undefined;
    var stderr_buf: [command_stderr_max]u8 = undefined;
    const result = try runCapture(
        &.{
            "nmcli",
            "--escape",
            "yes",
            "--terse",
            "--fields",
            "IN-USE,SSID,BSSID,SECURITY,SIGNAL",
            "device",
            "wifi",
            "list",
            "--rescan",
            "yes",
        },
        null,
        &stdout_buf,
        &stderr_buf,
    );
    if (!result.ok()) {
        return error.WifiScanFailed;
    }

    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        var index: usize = 0;
        var in_use_buf: [field_max_len]u8 = undefined;
        var ssid_buf: [field_max_len]u8 = undefined;
        var bssid_buf: [field_max_len]u8 = undefined;
        var security_buf: [field_max_len]u8 = undefined;
        var signal_buf: [field_max_len]u8 = undefined;

        const in_use = try readNmcliField(line, &index, &in_use_buf);
        const ssid = trimAscii(try readNmcliField(line, &index, &ssid_buf));
        const bssid = trimAscii(try readNmcliField(line, &index, &bssid_buf));
        const security = trimAscii(try readNmcliField(line, &index, &security_buf));
        const signal = trimAscii(try readNmcliField(line, &index, &signal_buf));

        if (ssid.len == 0 or networkExists(networks[0..count], ssid, bssid)) {
            continue;
        }
        if (count == networks.len) {
            return error.TooManyNetworks;
        }

        try networks[count].set(std.mem.eql(u8, in_use, "*"), ssid, bssid, security, signal);
        count += 1;
    }

    for (networks[0..count], 0..) |*network, index| {
        var duplicate_ssid = false;
        for (networks[0..count], 0..) |*other, other_index| {
            if (index == other_index) {
                continue;
            }
            if (std.mem.eql(u8, network.ssid(), other.ssid())) {
                duplicate_ssid = true;
                break;
            }
        }
        try network.buildLabel(duplicate_ssid);
    }

    return count;
}

fn chooseNetwork(networks: []const Network) !?usize {
    var menu_input: [menu_input_max]u8 = undefined;
    var menu_len: usize = 0;

    for (networks) |*network| {
        try appendBytes(&menu_input, &menu_len, network.label());
        try appendBytes(&menu_input, &menu_len, "\n");
    }

    var stdout_buf: [label_max_len + 8]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    const selection = try runCapture(
        &.{ "rofi", "-dmenu", "-i", "-p", "Wi-Fi" },
        menu_input[0..menu_len],
        &stdout_buf,
        &stderr_buf,
    );
    if (!selection.ok()) {
        return null;
    }

    const selected = trimAscii(selection.stdout);
    for (networks, 0..) |*network, index| {
        if (std.mem.eql(u8, selected, network.label())) {
            return index;
        }
    }

    return null;
}

fn disconnectCurrent(device: []const u8) void {
    var stdout_buf: [1024]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    _ = runCapture(&.{ "nmcli", "device", "disconnect", device }, null, &stdout_buf, &stderr_buf) catch {};
}

fn connect(
    network: *const Network,
    device: []const u8,
    password: ?[]const u8,
    stdout_buf: []u8,
    stderr_buf: []u8,
) !CommandResult {
    var argv_storage: [14][]const u8 = undefined;
    var argc: usize = 0;

    argv_storage[argc] = "nmcli";
    argc += 1;
    argv_storage[argc] = "--wait";
    argc += 1;
    argv_storage[argc] = "30";
    argc += 1;
    argv_storage[argc] = "device";
    argc += 1;
    argv_storage[argc] = "wifi";
    argc += 1;
    argv_storage[argc] = "connect";
    argc += 1;
    argv_storage[argc] = network.ssid();
    argc += 1;

    if (network.bssid_len > 0) {
        argv_storage[argc] = "bssid";
        argc += 1;
        argv_storage[argc] = network.bssid();
        argc += 1;
    }
    if (password) |secret| {
        argv_storage[argc] = "password";
        argc += 1;
        argv_storage[argc] = secret;
        argc += 1;
    }
    if (device.len > 0) {
        argv_storage[argc] = "ifname";
        argc += 1;
        argv_storage[argc] = device;
        argc += 1;
    }

    return runCapture(argv_storage[0..argc], null, stdout_buf, stderr_buf);
}

fn containsIgnoreAsciiCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) {
        return true;
    }
    if (needle.len > haystack.len) {
        return false;
    }

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                break;
            }
        } else {
            return true;
        }
    }

    return false;
}

fn needsPassword(result: CommandResult) bool {
    return containsIgnoreAsciiCase(result.stdout, "secrets were required") or
        containsIgnoreAsciiCase(result.stderr, "secrets were required") or
        containsIgnoreAsciiCase(result.stdout, "no password") or
        containsIgnoreAsciiCase(result.stderr, "no password") or
        containsIgnoreAsciiCase(result.stdout, "password") or
        containsIgnoreAsciiCase(result.stderr, "password") or
        containsIgnoreAsciiCase(result.stdout, "802-11-wireless-security") or
        containsIgnoreAsciiCase(result.stderr, "802-11-wireless-security");
}

fn promptPassword(ssid: []const u8, out: []u8) !?[]const u8 {
    var prompt_buf: ["Password for ".len + ssid_max_len]u8 = undefined;
    const prompt = try std.fmt.bufPrint(&prompt_buf, "Password for {s}", .{ssid});

    var stdout_buf: [password_max_len + 8]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    const result = try runCapture(
        &.{ "rofi", "-dmenu", "-password", "-p", prompt },
        "",
        &stdout_buf,
        &stderr_buf,
    );
    if (!result.ok()) {
        return null;
    }

    const password = trimTrailingNewline(result.stdout);
    if (password.len == 0) {
        return null;
    }

    const len = try copyInto(out, password);
    return out[0..len];
}

fn realMain() !u8 {
    var device_buf: [device_max_len]u8 = undefined;
    const device = (try wifiDevice(&device_buf)) orelse {
        rofiError("No Wi-Fi device found.");
        return 1;
    };

    var networks: [max_networks]Network = undefined;
    const network_count = try collectNetworks(&networks);
    if (network_count == 0) {
        rofiError("No Wi-Fi networks found.");
        return 1;
    }

    const selected_index = (try chooseNetwork(networks[0..network_count])) orelse return 0;
    const network = &networks[selected_index];

    if (network.active) {
        disconnectCurrent(device);
    }

    var connect_stdout_buf: [command_stdout_max]u8 = undefined;
    var connect_stderr_buf: [command_stderr_max]u8 = undefined;
    var result = try connect(network, device, null, &connect_stdout_buf, &connect_stderr_buf);
    if (result.ok()) {
        return 0;
    }

    if (network.security_len > 0 and needsPassword(result)) {
        var password_buf: [password_max_len]u8 = undefined;
        if (try promptPassword(network.ssid(), &password_buf)) |password| {
            result = try connect(network, device, password, &connect_stdout_buf, &connect_stderr_buf);
            if (result.ok()) {
                return 0;
            }
        } else {
            return 0;
        }
    }

    rofiError(if (result.stderr.len > 0) result.stderr else if (result.stdout.len > 0) result.stdout else "Could not connect to Wi-Fi.");
    return 1;
}

pub fn main() void {
    const code = realMain() catch |err| {
        const message = @errorName(err);
        std.debug.print("waybar-network-menu: {s}\n", .{message});
        rofiError(message);
        std.process.exit(1);
    };
    std.process.exit(code);
}
