const std = @import("std");
const log = @import("../log.zig");

const scoped_log = log.scoped("security");

/// Check if AppArmor is available on this system
pub fn isAppArmorAvailable() bool {
    std.fs.accessAbsolute("/sys/module/apparmor", .{}) catch return false;
    return true;
}

/// Check if SELinux is available on this system
pub fn isSELinuxAvailable() bool {
    std.fs.accessAbsolute("/sys/fs/selinux", .{}) catch return false;
    return true;
}

/// Apply an AppArmor profile before exec.
/// Must be called in the child process before execve.
/// The profile name comes from process.apparmorProfile in config.json.
pub fn applyAppArmorProfile(profile: []const u8) !void {
    if (!isAppArmorAvailable()) {
        scoped_log.debug("AppArmor not available, skipping profile", .{});
        return;
    }

    // Write "exec <profile>" to /proc/self/attr/apparmor/exec
    // Falls back to /proc/self/attr/exec on older kernels
    const paths = [_][]const u8{
        "/proc/self/attr/apparmor/exec",
        "/proc/self/attr/exec",
    };

    var buf: [256]u8 = undefined;
    const content = std.fmt.bufPrint(&buf, "exec {s}", .{profile}) catch return error.InvalidProfile;

    for (paths) |path| {
        const file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch continue;
        defer file.close();
        file.writeAll(content) catch continue;
        scoped_log.debug("Applied AppArmor profile: {s}", .{profile});
        return;
    }

    scoped_log.warn("Failed to apply AppArmor profile: {s}", .{profile});
    return error.ProfileApplicationFailed;
}

/// Apply an SELinux label before exec.
/// Must be called in the child process before execve.
/// The label comes from process.selinuxLabel in config.json.
pub fn applySELinuxLabel(label: []const u8) !void {
    if (!isSELinuxAvailable()) {
        scoped_log.debug("SELinux not available, skipping label", .{});
        return;
    }

    // Write the label to /proc/self/attr/exec
    const file = std.fs.openFileAbsolute("/proc/self/attr/exec", .{ .mode = .write_only }) catch |err| {
        scoped_log.warn("Cannot open /proc/self/attr/exec: {}", .{err});
        return error.LabelApplicationFailed;
    };
    defer file.close();
    file.writeAll(label) catch |err| {
        scoped_log.warn("Cannot set SELinux label: {}", .{err});
        return error.LabelApplicationFailed;
    };

    scoped_log.debug("Applied SELinux label: {s}", .{label});
}

/// Apply security profiles from the OCI runtime spec process config.
/// Call this in the child after namespace setup, before execve.
pub fn applyProcessSecurity(
    apparmor_profile: ?[]const u8,
    selinux_label: ?[]const u8,
) void {
    if (apparmor_profile) |profile| {
        applyAppArmorProfile(profile) catch {};
    }
    if (selinux_label) |label| {
        applySELinuxLabel(label) catch {};
    }
}

test "AppArmor availability check compiles" {
    _ = isAppArmorAvailable();
}

test "SELinux availability check compiles" {
    _ = isSELinuxAvailable();
}
