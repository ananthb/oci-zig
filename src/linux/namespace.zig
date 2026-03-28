const std = @import("std");
const linux = std.os.linux;
const syscall = @import("syscall.zig");
const log = @import("../log.zig");

const scoped_log = log.scoped("namespace");

pub const IsolationLevel = enum {
    full, // User + mount + PID + network namespaces + seccomp
    privileged, // Mount + PID + network namespaces (no user ns, requires root)
    chroot_only, // Bare chroot (fallback)
};

/// Detect the best available isolation level
pub fn detectIsolationLevel() IsolationLevel {
    // Check if running as root
    if (linux.getuid() == 0) {
        return .privileged;
    }

    // Check if unprivileged user namespaces are available
    const userns_available = blk: {
        const file = std.fs.openFileAbsolute("/proc/sys/kernel/unprivileged_userns_clone", .{}) catch {
            // File doesn't exist - user namespaces may still work (many kernels don't have this sysctl)
            break :blk true;
        };
        defer file.close();
        var buf: [8]u8 = undefined;
        const n = file.readAll(&buf) catch break :blk false;
        if (n > 0 and buf[0] == '1') {
            break :blk true;
        }
        break :blk false;
    };

    if (userns_available) {
        return .full;
    }

    return .chroot_only;
}

/// Write UID map for a child process
pub fn writeUidMap(child_pid: i32, outer_uid: u32) !void {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/uid_map", .{child_pid}) catch return error.InvalidArgument;

    var content_buf: [32]u8 = undefined;
    const content = std.fmt.bufPrint(&content_buf, "0 {d} 1\n", .{outer_uid}) catch return error.InvalidArgument;

    writeFileContent(path, content) catch |err| {
        scoped_log.err("Failed to write uid_map: {}", .{err});
        return err;
    };
}

/// Write GID map for a child process (must deny setgroups first)
pub fn writeGidMap(child_pid: i32, outer_gid: u32) !void {
    // Deny setgroups first (required on kernels 3.19+)
    var setgroups_buf: [64]u8 = undefined;
    const setgroups_path = std.fmt.bufPrint(&setgroups_buf, "/proc/{d}/setgroups", .{child_pid}) catch return error.InvalidArgument;
    writeFileContent(setgroups_path, "deny\n") catch {};

    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/gid_map", .{child_pid}) catch return error.InvalidArgument;

    var content_buf: [32]u8 = undefined;
    const content = std.fmt.bufPrint(&content_buf, "0 {d} 1\n", .{outer_gid}) catch return error.InvalidArgument;

    writeFileContent(path, content) catch |err| {
        scoped_log.err("Failed to write gid_map: {}", .{err});
        return err;
    };
}

/// Write a multi-range UID map for rootless containers.
/// Reads /etc/subuid to find the subordinate UID range for the current user.
pub fn writeUidMapRootless(child_pid: i32, allocator: std.mem.Allocator) !void {
    const outer_uid = linux.getuid();

    // Map container root (0) to our UID
    // Map container 1-65535 to our subordinate range
    const sub_range = readSubRange(allocator, "/etc/subuid", outer_uid) catch {
        // Fallback: single UID mapping
        return writeUidMap(child_pid, outer_uid);
    };

    var content_buf: [128]u8 = undefined;
    const content = std.fmt.bufPrint(&content_buf, "0 {d} 1\n1 {d} {d}\n", .{
        outer_uid, sub_range.start, sub_range.count,
    }) catch return error.InvalidArgument;

    // Need newuidmap helper for multi-range mapping (kernel requires it for unprivileged)
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/uid_map", .{child_pid}) catch return error.InvalidArgument;
    writeFileContent(path, content) catch {
        // Multi-range write failed (common without newuidmap setuid helper).
        // Fall back to single mapping.
        return writeUidMap(child_pid, outer_uid);
    };
}

/// Write a multi-range GID map for rootless containers.
pub fn writeGidMapRootless(child_pid: i32, allocator: std.mem.Allocator) !void {
    const outer_gid = linux.getgid();

    // Deny setgroups first
    var setgroups_buf: [64]u8 = undefined;
    const setgroups_path = std.fmt.bufPrint(&setgroups_buf, "/proc/{d}/setgroups", .{child_pid}) catch return error.InvalidArgument;
    writeFileContent(setgroups_path, "deny\n") catch {};

    const sub_range = readSubRange(allocator, "/etc/subgid", outer_gid) catch {
        return writeGidMap(child_pid, outer_gid);
    };

    var content_buf: [128]u8 = undefined;
    const content = std.fmt.bufPrint(&content_buf, "0 {d} 1\n1 {d} {d}\n", .{
        outer_gid, sub_range.start, sub_range.count,
    }) catch return error.InvalidArgument;

    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/gid_map", .{child_pid}) catch return error.InvalidArgument;
    writeFileContent(path, content) catch {
        return writeGidMap(child_pid, outer_gid);
    };
}

const SubRange = struct { start: u32, count: u32 };

/// Parse /etc/subuid or /etc/subgid for a given UID/GID
fn readSubRange(allocator: std.mem.Allocator, path: []const u8, id: u32) !SubRange {
    const file = std.fs.openFileAbsolute(path, .{}) catch return error.NotFound;
    defer file.close();

    var buf: [4096]u8 = undefined;
    const n = file.readAll(&buf) catch return error.ReadFailed;

    // Format: username:start:count or uid:start:count
    var id_buf: [16]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch return error.InvalidArgument;

    // Also get username for matching
    var username: ?[]const u8 = null;
    const passwd = std.fs.openFileAbsolute("/etc/passwd", .{}) catch null;
    if (passwd) |pw| {
        defer pw.close();
        var pw_buf: [4096]u8 = undefined;
        const pw_n = pw.readAll(&pw_buf) catch 0;
        var pw_lines = std.mem.splitScalar(u8, pw_buf[0..pw_n], '\n');
        while (pw_lines.next()) |line| {
            var fields = std.mem.splitScalar(u8, line, ':');
            const name = fields.next() orelse continue;
            _ = fields.next(); // password
            const uid_field = fields.next() orelse continue;
            if (std.mem.eql(u8, uid_field, id_str)) {
                username = allocator.dupe(u8, name) catch null;
                break;
            }
        }
    }
    defer if (username) |u| allocator.free(u);

    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const field_name = fields.next() orelse continue;
        const start_str = fields.next() orelse continue;
        const count_str = fields.next() orelse continue;

        const matches = std.mem.eql(u8, field_name, id_str) or
            (username != null and std.mem.eql(u8, field_name, username.?));

        if (matches) {
            const start = std.fmt.parseInt(u32, start_str, 10) catch continue;
            const count = std.fmt.parseInt(u32, count_str, 10) catch continue;
            return SubRange{ .start = start, .count = count };
        }
    }

    return error.NotFound;
}

/// Check if we're running rootless (non-root without user namespace)
pub fn isRootless() bool {
    return linux.getuid() != 0;
}

fn writeFileContent(path: []const u8, content: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse "/";
    var dir = try std.fs.openDirAbsolute(dir_path, .{});
    defer dir.close();
    var file = try dir.openFile(std.fs.path.basename(path), .{ .mode = .write_only });
    defer file.close();
    try file.writeAll(content);
}

test "IsolationLevel enum" {
    const level = IsolationLevel.full;
    try std.testing.expect(level == .full);

    const chroot = IsolationLevel.chroot_only;
    try std.testing.expect(chroot == .chroot_only);
}

test "uid map content format" {
    // Verify the format we'd write to uid_map
    var buf: [32]u8 = undefined;
    const content = std.fmt.bufPrint(&buf, "0 {d} 1\n", .{@as(u32, 1000)}) catch unreachable;
    try std.testing.expectEqualStrings("0 1000 1\n", content);
}

test "gid map content format" {
    // Verify the format we'd write to gid_map
    var buf: [32]u8 = undefined;
    const content = std.fmt.bufPrint(&buf, "0 {d} 1\n", .{@as(u32, 1000)}) catch unreachable;
    try std.testing.expectEqualStrings("0 1000 1\n", content);
}
