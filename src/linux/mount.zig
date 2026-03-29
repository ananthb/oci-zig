const std = @import("std");
const syscall = @import("syscall.zig");
const log = @import("../log.zig");

pub const MountError = syscall.SyscallError || error{
    PathTooLong,
    AllocationFailed,
};

/// Mount information from /proc/mounts
pub const MountInfo = struct {
    source: []const u8,
    target: []const u8,
    fstype: []const u8,
    options: []const u8,

    pub fn deinit(self: *MountInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        allocator.free(self.target);
        allocator.free(self.fstype);
        allocator.free(self.options);
    }
};

/// Bind mount a directory
pub fn bindMount(source: []const u8, target: []const u8) MountError!void {
    var source_buf: [std.fs.max_path_bytes]u8 = undefined;
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;

    if (source.len >= source_buf.len or target.len >= target_buf.len) {
        return error.PathTooLong;
    }

    @memcpy(source_buf[0..source.len], source);
    source_buf[source.len] = 0;

    @memcpy(target_buf[0..target.len], target);
    target_buf[target.len] = 0;

    const source_z: [*:0]const u8 = @ptrCast(source_buf[0..source.len :0]);
    const target_z: [*:0]const u8 = @ptrCast(target_buf[0..target.len :0]);

    log.debug("Bind mounting {s} to {s}", .{ source, target });
    try syscall.mount(source_z, target_z, null, .{ .bind = true }, null);
}

/// Recursive bind mount
pub fn bindMountRec(source: []const u8, target: []const u8) MountError!void {
    var source_buf: [std.fs.max_path_bytes]u8 = undefined;
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;

    if (source.len >= source_buf.len or target.len >= target_buf.len) {
        return error.PathTooLong;
    }

    @memcpy(source_buf[0..source.len], source);
    source_buf[source.len] = 0;

    @memcpy(target_buf[0..target.len], target);
    target_buf[target.len] = 0;

    const source_z: [*:0]const u8 = @ptrCast(source_buf[0..source.len :0]);
    const target_z: [*:0]const u8 = @ptrCast(target_buf[0..target.len :0]);

    log.debug("Recursive bind mounting {s} to {s}", .{ source, target });
    try syscall.mount(source_z, target_z, null, .{ .bind = true, .rec = true }, null);
}

/// Move mount to new location
pub fn moveMount(source: []const u8, target: []const u8) MountError!void {
    var source_buf: [std.fs.max_path_bytes]u8 = undefined;
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;

    if (source.len >= source_buf.len or target.len >= target_buf.len) {
        return error.PathTooLong;
    }

    @memcpy(source_buf[0..source.len], source);
    source_buf[source.len] = 0;

    @memcpy(target_buf[0..target.len], target);
    target_buf[target.len] = 0;

    const source_z: [*:0]const u8 = @ptrCast(source_buf[0..source.len :0]);
    const target_z: [*:0]const u8 = @ptrCast(target_buf[0..target.len :0]);

    log.debug("Moving mount {s} to {s}", .{ source, target });
    try syscall.mount(source_z, target_z, null, .{ .move = true }, null);
}

/// Mount a tmpfs at target
pub fn mountTmpfs(target: []const u8, options: ?[]const u8) MountError!void {
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;

    if (target.len >= target_buf.len) {
        return error.PathTooLong;
    }

    @memcpy(target_buf[0..target.len], target);
    target_buf[target.len] = 0;

    const target_z: [*:0]const u8 = @ptrCast(target_buf[0..target.len :0]);

    var opts_buf: [256]u8 = undefined;
    var opts_z: ?[*]const u8 = null;
    if (options) |opts| {
        if (opts.len >= opts_buf.len) {
            return error.PathTooLong;
        }
        @memcpy(opts_buf[0..opts.len], opts);
        opts_buf[opts.len] = 0;
        opts_z = @ptrCast(&opts_buf);
    }

    log.debug("Mounting tmpfs at {s}", .{target});
    try syscall.mount("tmpfs", target_z, "tmpfs", .{}, opts_z);
}

/// Unmount a filesystem
pub fn umountPath(target: []const u8) MountError!void {
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;

    if (target.len >= target_buf.len) {
        return error.PathTooLong;
    }

    @memcpy(target_buf[0..target.len], target);
    target_buf[target.len] = 0;

    const target_z: [*:0]const u8 = @ptrCast(target_buf[0..target.len :0]);

    log.debug("Unmounting {s}", .{target});
    try syscall.umount(target_z, .{});
}

/// Lazy unmount (detach) a filesystem
pub fn umountDetach(target: []const u8) MountError!void {
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;

    if (target.len >= target_buf.len) {
        return error.PathTooLong;
    }

    @memcpy(target_buf[0..target.len], target);
    target_buf[target.len] = 0;

    const target_z: [*:0]const u8 = @ptrCast(target_buf[0..target.len :0]);

    log.debug("Lazy unmounting {s}", .{target});
    try syscall.umount(target_z, .{ .detach = true });
}

/// Make a mount point private (no propagation)
pub fn makePrivate(target: []const u8) MountError!void {
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;

    if (target.len >= target_buf.len) {
        return error.PathTooLong;
    }

    @memcpy(target_buf[0..target.len], target);
    target_buf[target.len] = 0;

    const target_z: [*:0]const u8 = @ptrCast(target_buf[0..target.len :0]);

    log.debug("Making {s} private", .{target});
    try syscall.mount(null, target_z, null, .{ .private = true, .rec = true }, null);
}

/// Make a mount point shared (propagation enabled)
pub fn makeShared(target: []const u8) MountError!void {
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;

    if (target.len >= target_buf.len) {
        return error.PathTooLong;
    }

    @memcpy(target_buf[0..target.len], target);
    target_buf[target.len] = 0;

    const target_z: [*:0]const u8 = @ptrCast(target_buf[0..target.len :0]);

    log.debug("Making {s} shared", .{target});
    try syscall.mount(null, target_z, null, .{ .shared = true, .rec = true }, null);
}

/// Read current mounts from /proc/mounts
pub fn readMounts(allocator: std.mem.Allocator) ![]MountInfo {
    var mounts: std.ArrayListUnmanaged(MountInfo) = .{};
    errdefer {
        for (mounts.items) |*m| {
            m.deinit(allocator);
        }
        mounts.deinit(allocator);
    }

    const file = try std.fs.openFileAbsolute("/proc/mounts", .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    const n = file.readAll(&buf) catch 0;
    const content = buf[0..n];

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parts = std.mem.splitScalar(u8, line, ' ');

        const source = parts.next() orelse continue;
        const target = parts.next() orelse continue;
        const fstype = parts.next() orelse continue;
        const options = parts.next() orelse continue;

        try mounts.append(allocator, .{
            .source = try allocator.dupe(u8, source),
            .target = try allocator.dupe(u8, target),
            .fstype = try allocator.dupe(u8, fstype),
            .options = try allocator.dupe(u8, options),
        });
    }

    return mounts.toOwnedSlice(allocator);
}

/// Check if a path is a mount point
pub fn isMountPoint(path: []const u8, allocator: std.mem.Allocator) !bool {
    const mounts = try readMounts(allocator);
    defer {
        for (mounts) |*m| {
            var m_copy = m.*;
            m_copy.deinit(allocator);
        }
        allocator.free(mounts);
    }

    for (mounts) |m| {
        if (std.mem.eql(u8, m.target, path)) {
            return true;
        }
    }
    return false;
}

/// Ensure a path is a mount point (bind mount to itself if needed)
pub fn ensureMountPoint(path: []const u8) MountError!void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    if (path.len >= path_buf.len) {
        return error.PathTooLong;
    }

    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const path_z: [*:0]const u8 = @ptrCast(path_buf[0..path.len :0]);

    log.debug("Ensuring {s} is a mount point", .{path});
    // Bind mount to itself to make it a mount point
    try syscall.mount(path_z, path_z, null, .{ .bind = true }, null);
}

/// Create directory if it doesn't exist
pub fn ensureDir(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

pub const PivotError = error{
    PivotRootFailed,
    ChdirFailed,
    ChrootFailed,
    PathTooLong,
};

/// Perform pivot_root with fallback to switch_root approach.
/// new_root: path to new root filesystem
/// put_old: path where old root will be mounted (relative to new_root)
pub fn pivotRoot(new_root: []const u8, put_old: []const u8) PivotError!void {
    var new_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    var put_old_buf: [std.fs.max_path_bytes]u8 = undefined;

    if (new_root.len >= new_root_buf.len or put_old.len >= put_old_buf.len) {
        return error.PathTooLong;
    }

    @memcpy(new_root_buf[0..new_root.len], new_root);
    new_root_buf[new_root.len] = 0;
    const new_root_z: [*:0]const u8 = @ptrCast(new_root_buf[0..new_root.len :0]);

    const put_old_abs = if (std.fs.path.isAbsolute(put_old))
        put_old
    else blk: {
        @memcpy(put_old_buf[0..new_root.len], new_root);
        put_old_buf[new_root.len] = '/';
        @memcpy(put_old_buf[new_root.len + 1 ..][0..put_old.len], put_old);
        put_old_buf[new_root.len + 1 + put_old.len] = 0;
        break :blk put_old_buf[0 .. new_root.len + 1 + put_old.len];
    };

    const put_old_z: [*:0]const u8 = @ptrCast(put_old_abs.ptr);

    // Try pivot_root first
    syscall.pivotRoot(new_root_z, put_old_z) catch |err| {
        log.warn("pivot_root failed: {}, trying switch_root fallback", .{err});

        // Fallback to switch_root: chdir + mount move + chroot
        syscall.chdir(new_root_z) catch return error.ChdirFailed;
        syscall.mount(".", "/", null, .{ .move = true }, null) catch return error.PivotRootFailed;
        syscall.chroot(".") catch return error.ChrootFailed;
        syscall.chdir("/") catch return error.ChdirFailed;
        return;
    };

    syscall.chdir("/") catch return error.ChdirFailed;
}

test "mount info parsing" {
    // This test just verifies the structure compiles
    const info = MountInfo{
        .source = "/dev/sda1",
        .target = "/",
        .fstype = "ext4",
        .options = "rw,relatime",
    };
    _ = info;
}
