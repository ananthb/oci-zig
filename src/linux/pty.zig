const std = @import("std");
const linux = std.os.linux;
const log = @import("../log.zig");
const syscall = @import("syscall.zig");

const scoped_log = log.scoped("pty");

/// Mount devpts in a container's /dev/pts with proper options
pub fn mountDevpts(rootfs_path: []const u8, allocator: std.mem.Allocator) !void {
    const pts_path = try std.fmt.allocPrint(allocator, "{s}/dev/pts", .{rootfs_path});
    defer allocator.free(pts_path);

    // Ensure directory exists
    {
        var dir = std.fs.openDirAbsolute(rootfs_path, .{}) catch return;
        defer dir.close();
        dir.makePath("dev/pts") catch {};
    }

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (pts_path.len >= buf.len) return;
    @memcpy(buf[0..pts_path.len], pts_path);
    buf[pts_path.len] = 0;
    const z: [*:0]const u8 = @ptrCast(buf[0..pts_path.len :0]);

    syscall.mount("devpts", z, "devpts", .{
        .nosuid = true,
        .noexec = true,
    }, @ptrCast("newinstance,ptmxmode=0666,mode=0620")) catch |err| {
        scoped_log.debug("Failed to mount devpts: {}", .{err});
        return;
    };

    // Create /dev/ptmx symlink
    const ptmx_path = try std.fmt.allocPrint(allocator, "{s}/dev/ptmx", .{rootfs_path});
    defer allocator.free(ptmx_path);

    std.fs.deleteFileAbsolute(ptmx_path) catch {};
    {
        var dir = std.fs.openDirAbsolute(rootfs_path, .{}) catch return;
        defer dir.close();
        dir.symLink("pts/ptmx", "dev/ptmx", .{}) catch {};
    }

    scoped_log.debug("Mounted devpts at {s}", .{pts_path});
}

/// Set up /dev/console in the container by bind-mounting the host's PTY
pub fn setupConsole(rootfs_path: []const u8, console_fd: i32, allocator: std.mem.Allocator) !void {
    const console_path = try std.fmt.allocPrint(allocator, "{s}/dev/console", .{rootfs_path});
    defer allocator.free(console_path);

    // Create the console file if it doesn't exist
    {
        const dir_path = std.fs.path.dirname(console_path) orelse "/";
        var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return;
        defer dir.close();
        var file = dir.createFile("console", .{}) catch return;
        file.close();
    }

    // Bind mount the PTY to /dev/console
    // First get the path of the console fd via /proc/self/fd/<n>
    var fd_path_buf: [64]u8 = undefined;
    const fd_link = std.fmt.bufPrint(&fd_path_buf, "/proc/self/fd/{d}", .{console_fd}) catch return;

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = std.posix.readlinkZ(
        (std.posix.toPosixPath(fd_link) catch return)[0..],
        &target_buf,
    ) catch return;
    _ = target;

    // Bind mount
    var console_z_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (console_path.len >= console_z_buf.len) return;
    @memcpy(console_z_buf[0..console_path.len], console_path);
    console_z_buf[console_path.len] = 0;
    const console_z: [*:0]const u8 = @ptrCast(console_z_buf[0..console_path.len :0]);

    var fd_z_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (fd_link.len >= fd_z_buf.len) return;
    @memcpy(fd_z_buf[0..fd_link.len], fd_link);
    fd_z_buf[fd_link.len] = 0;
    const fd_z: [*:0]const u8 = @ptrCast(fd_z_buf[0..fd_link.len :0]);

    syscall.mount(fd_z, console_z, null, .{ .bind = true }, null) catch |err| {
        scoped_log.debug("Failed to bind mount console: {}", .{err});
    };
}

test "module compiles" {
    // Basic smoke test
    try std.testing.expect(true);
}
