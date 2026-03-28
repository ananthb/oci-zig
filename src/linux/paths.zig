const std = @import("std");
const syscall = @import("syscall.zig");
const log = @import("../log.zig");

const scoped_log = log.scoped("paths");

/// Default masked paths (bind-mount /dev/null over these)
pub const default_masked_paths = [_][]const u8{
    "/proc/asound",
    "/proc/acpi",
    "/proc/kcore",
    "/proc/keys",
    "/proc/latency_stats",
    "/proc/timer_list",
    "/proc/timer_stats",
    "/proc/sched_debug",
    "/proc/scsi",
    "/sys/firmware",
    "/sys/devices/virtual/powercap",
};

/// Default readonly paths (bind-mount then remount read-only)
pub const default_readonly_paths = [_][]const u8{
    "/proc/bus",
    "/proc/fs",
    "/proc/irq",
    "/proc/sys",
    "/proc/sysrq-trigger",
};

/// Apply masked paths: bind-mount /dev/null over each path.
/// This prevents container processes from reading sensitive host info.
pub fn applyMaskedPaths(rootfs: []const u8, paths: []const []const u8, allocator: std.mem.Allocator) void {
    for (paths) |path| {
        const full = std.fmt.allocPrint(allocator, "{s}{s}", .{ rootfs, path }) catch continue;
        defer allocator.free(full);

        // Check if the path exists (file or directory)
        std.fs.accessAbsolute(full, .{}) catch continue;

        var full_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (full.len >= full_buf.len) continue;
        @memcpy(full_buf[0..full.len], full);
        full_buf[full.len] = 0;
        const full_z: [*:0]const u8 = @ptrCast(full_buf[0..full.len :0]);

        // Bind mount /dev/null over the path
        syscall.mount("/dev/null", full_z, null, .{ .bind = true }, null) catch {
            // If it's a directory, try mounting tmpfs instead
            syscall.mount("tmpfs", full_z, "tmpfs", .{ .rdonly = true }, null) catch {
                scoped_log.debug("Cannot mask {s}", .{path});
            };
        };
    }
}

/// Apply readonly paths: bind-mount then remount read-only.
pub fn applyReadonlyPaths(rootfs: []const u8, paths: []const []const u8, allocator: std.mem.Allocator) void {
    for (paths) |path| {
        const full = std.fmt.allocPrint(allocator, "{s}{s}", .{ rootfs, path }) catch continue;
        defer allocator.free(full);

        std.fs.accessAbsolute(full, .{}) catch continue;

        var full_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (full.len >= full_buf.len) continue;
        @memcpy(full_buf[0..full.len], full);
        full_buf[full.len] = 0;
        const full_z: [*:0]const u8 = @ptrCast(full_buf[0..full.len :0]);

        // Bind mount the path onto itself
        syscall.mount(full_z, full_z, null, .{ .bind = true, .rec = true }, null) catch continue;

        // Remount read-only
        syscall.mount(null, full_z, null, .{ .remount = true, .bind = true, .rdonly = true }, null) catch {
            scoped_log.debug("Cannot make {s} readonly", .{path});
        };
    }
}

/// Apply both default masked and readonly paths
pub fn applyDefaults(rootfs: []const u8, allocator: std.mem.Allocator) void {
    applyMaskedPaths(rootfs, &default_masked_paths, allocator);
    applyReadonlyPaths(rootfs, &default_readonly_paths, allocator);
}

test "default paths defined" {
    try std.testing.expect(default_masked_paths.len > 0);
    try std.testing.expect(default_readonly_paths.len > 0);
}
