const std = @import("std");
const log = @import("../log.zig");

const scoped_log = log.scoped("sysctl");

pub const SysctlError = error{
    WriteFailed,
    PathTooLong,
    InvalidKey,
};

/// Well-known container sysctl keys
pub const well_known = struct {
    pub const net_ipv4_ip_forward = "net.ipv4.ip_forward";
    pub const net_ipv4_ping_group_range = "net.ipv4.ping_group_range";
    pub const net_ipv4_ip_unprivileged_port_start = "net.ipv4.ip_unprivileged_port_start";
    pub const net_ipv4_ip_local_port_range = "net.ipv4.ip_local_port_range";
    pub const net_core_somaxconn = "net.core.somaxconn";
    pub const kernel_shm_rmid_forced = "kernel.shm_rmid_forced";
    pub const kernel_msgmax = "kernel.msgmax";
    pub const kernel_msgmnb = "kernel.msgmnb";
    pub const kernel_msgmni = "kernel.msgmni";
    pub const kernel_sem = "kernel.sem";
    pub const kernel_shmall = "kernel.shmall";
    pub const kernel_shmmax = "kernel.shmmax";
    pub const kernel_shmmni = "kernel.shmmni";
};

/// Apply a set of sysctl key=value pairs by writing to /proc/sys/.
/// Keys use dot notation (e.g. "net.ipv4.ip_forward") which is converted
/// to path notation (e.g. "/proc/sys/net/ipv4/ip_forward").
pub fn applySysctls(sysctls: []const SysctlEntry) void {
    for (sysctls) |entry| {
        applySysctl(entry.key, entry.value) catch |err| {
            scoped_log.warn("Failed to apply sysctl {s}={s}: {}", .{ entry.key, entry.value, err });
        };
    }
}

/// A single sysctl key-value pair
pub const SysctlEntry = struct {
    key: []const u8,
    value: []const u8,
};

/// Apply a single sysctl by writing to /proc/sys/<key>.
fn applySysctl(key: []const u8, value: []const u8) SysctlError!void {
    if (key.len == 0) return error.InvalidKey;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prefix = "/proc/sys/";

    // Build path: /proc/sys/ + key with '.' replaced by '/'
    if (prefix.len + key.len >= path_buf.len) return error.PathTooLong;

    @memcpy(path_buf[0..prefix.len], prefix);
    var pos: usize = prefix.len;
    for (key) |c| {
        path_buf[pos] = if (c == '.') '/' else c;
        pos += 1;
    }

    const path = path_buf[0..pos];
    const file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch {
        scoped_log.debug("Cannot open {s}", .{path});
        return error.WriteFailed;
    };
    defer file.close();

    file.writeAll(value) catch {
        scoped_log.debug("Cannot write to {s}", .{path});
        return error.WriteFailed;
    };

    scoped_log.debug("Applied sysctl {s}={s}", .{ key, value });
}

/// Check if a sysctl key is safe to set inside a container namespace.
/// Only net.* and certain kernel.shm/kernel.msg/kernel.sem keys are
/// considered safe in a namespaced context.
pub fn isSafeForContainer(key: []const u8) bool {
    // net.* sysctls are namespaced and safe
    if (std.mem.startsWith(u8, key, "net.")) return true;

    // IPC-related kernel sysctls are namespaced
    const safe_prefixes = [_][]const u8{
        "kernel.shm_rmid_forced",
        "kernel.msgmax",
        "kernel.msgmnb",
        "kernel.msgmni",
        "kernel.sem",
        "kernel.shmall",
        "kernel.shmmax",
        "kernel.shmmni",
    };
    for (safe_prefixes) |prefix| {
        if (std.mem.eql(u8, key, prefix)) return true;
    }

    return false;
}

/// Convert a sysctl key to its /proc/sys path.
/// Caller must ensure buf is large enough.
pub fn keyToPath(key: []const u8, buf: []u8) SysctlError![]const u8 {
    const prefix = "/proc/sys/";
    if (prefix.len + key.len >= buf.len) return error.PathTooLong;
    if (key.len == 0) return error.InvalidKey;

    @memcpy(buf[0..prefix.len], prefix);
    var pos: usize = prefix.len;
    for (key) |c| {
        buf[pos] = if (c == '.') '/' else c;
        pos += 1;
    }
    return buf[0..pos];
}

test "keyToPath converts dots to slashes" {
    var buf: [256]u8 = undefined;
    const path = try keyToPath("net.ipv4.ip_forward", &buf);
    try std.testing.expectEqualStrings("/proc/sys/net/ipv4/ip_forward", path);
}

test "keyToPath kernel key" {
    var buf: [256]u8 = undefined;
    const path = try keyToPath("kernel.shm_rmid_forced", &buf);
    try std.testing.expectEqualStrings("/proc/sys/kernel/shm_rmid_forced", path);
}

test "isSafeForContainer" {
    try std.testing.expect(isSafeForContainer("net.ipv4.ip_forward"));
    try std.testing.expect(isSafeForContainer("net.core.somaxconn"));
    try std.testing.expect(isSafeForContainer("kernel.shm_rmid_forced"));
    try std.testing.expect(!isSafeForContainer("kernel.panic"));
    try std.testing.expect(!isSafeForContainer("vm.swappiness"));
}

test "keyToPath empty key" {
    var buf: [256]u8 = undefined;
    try std.testing.expectError(error.InvalidKey, keyToPath("", &buf));
}
