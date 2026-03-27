const std = @import("std");
const linux = std.os.linux;
const log = @import("log.zig");

const scoped_log = log.scoped("run");

pub const RunError = error{
    CommandFailed,
    SetupFailed,
    OutOfMemory,
};

/// Execute a command inside a rootfs using chroot.
/// Sets up /proc, /dev, /sys, /etc/resolv.conf for the command,
/// then cleans up after it exits.
pub fn executeInRootfs(
    allocator: std.mem.Allocator,
    rootfs_path: []const u8,
    argv: []const []const u8,
    env: ?[]const []const u8,
) RunError!void {
    if (argv.len == 0) return;

    scoped_log.info("RUN: {s}", .{argv[0]});

    setupMounts(allocator, rootfs_path) catch |err| {
        scoped_log.warn("Mount setup failed: {}, continuing anyway", .{err});
    };
    defer cleanupMounts(allocator, rootfs_path);

    setupDns(allocator, rootfs_path) catch {};

    // Fork a child to do the chroot + exec
    const fork_result = if (@hasField(linux.SYS, "fork"))
        linux.syscall0(.fork)
    else
        linux.syscall5(.clone, linux.SIG.CHLD, 0, 0, 0, 0);

    if (linux.E.init(fork_result) != .SUCCESS) {
        scoped_log.err("fork failed", .{});
        return error.CommandFailed;
    }

    if (fork_result == 0) {
        // Child: chroot, chdir, exec
        runInChild(allocator, rootfs_path, argv, env);
        std.process.exit(127);
    }

    // Parent: wait for child
    const child_pid: i32 = @intCast(fork_result);
    var status: u32 = 0;
    while (true) {
        const wait_result = linux.syscall4(
            .wait4,
            @as(usize, @intCast(child_pid)),
            @intFromPtr(&status),
            0,
            0,
        );
        if (linux.E.init(wait_result) == .INTR) continue;
        break;
    }

    const exit_code = (status >> 8) & 0xFF;
    if (exit_code != 0) {
        scoped_log.err("RUN command exited with status {}", .{exit_code});
        return error.CommandFailed;
    }
}

fn runInChild(
    allocator: std.mem.Allocator,
    rootfs_path: []const u8,
    argv: []const []const u8,
    env: ?[]const []const u8,
) void {
    const rootfs_z = allocator.dupeZ(u8, rootfs_path) catch return;
    sysChroot(rootfs_z) catch {
        std.debug.print("xenomorph: chroot failed\n", .{});
        return;
    };
    sysChdirSlash() catch return;

    // Build null-terminated argv
    var c_argv: std.ArrayListUnmanaged(?[*:0]const u8) = .{};
    for (argv) |arg| {
        const z = allocator.dupeZ(u8, arg) catch return;
        c_argv.append(allocator, z) catch return;
    }
    c_argv.append(allocator, null) catch return;

    // Build null-terminated envp
    var c_envp: std.ArrayListUnmanaged(?[*:0]const u8) = .{};
    if (env) |env_list| {
        for (env_list) |e| {
            const z = allocator.dupeZ(u8, e) catch return;
            c_envp.append(allocator, z) catch return;
        }
    } else {
        for ([_][]const u8{
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "HOME=/root",
            "TERM=xterm",
        }) |e| {
            const z = allocator.dupeZ(u8, e) catch return;
            c_envp.append(allocator, z) catch return;
        }
    }
    c_envp.append(allocator, null) catch return;

    const cmd_z = allocator.dupeZ(u8, argv[0]) catch return;
    const err = std.posix.execveZ(cmd_z, @ptrCast(c_argv.items.ptr), @ptrCast(c_envp.items.ptr));
    std.debug.print("xenomorph: execve failed: {}\n", .{err});
}

// --- Linux syscall wrappers ---

fn sysChroot(path: [*:0]const u8) !void {
    const result = linux.syscall1(.chroot, @intFromPtr(path));
    if (linux.E.init(result) != .SUCCESS) return error.SetupFailed;
}

fn sysChdirSlash() !void {
    const result = linux.syscall1(.chdir, @intFromPtr(@as([*:0]const u8, "/")));
    if (linux.E.init(result) != .SUCCESS) return error.SetupFailed;
}

const MS_NOSUID: u32 = 2;
const MS_NOEXEC: u32 = 8;
const MS_NODEV: u32 = 4;
const MS_BIND: u32 = 4096;
const MS_REC: u32 = 16384;
const MNT_DETACH: u32 = 2;

fn sysMount(source: [*:0]const u8, target: [*:0]const u8, fstype: ?[*:0]const u8, flags: u32) void {
    _ = linux.syscall5(
        .mount,
        @intFromPtr(source),
        @intFromPtr(target),
        if (fstype) |f| @intFromPtr(f) else 0,
        flags,
        0,
    );
}

fn sysUmount(target: [*:0]const u8) void {
    _ = linux.syscall2(.umount2, @intFromPtr(target), MNT_DETACH);
}

fn setupMounts(allocator: std.mem.Allocator, rootfs_path: []const u8) !void {
    {
        var dir = try std.fs.openDirAbsolute(rootfs_path, .{});
        defer dir.close();
        dir.makePath("proc") catch {};
        dir.makePath("dev") catch {};
        dir.makePath("sys") catch {};
        dir.makePath("etc") catch {};
    }

    // Mount /proc
    const proc_path = try allocator.dupeZ(u8, try std.fmt.allocPrint(allocator, "{s}/proc", .{rootfs_path}));
    defer allocator.free(proc_path[0 .. proc_path.len + 1]);
    sysMount("proc", proc_path, "proc", MS_NOSUID | MS_NOEXEC | MS_NODEV);

    // Bind mount /dev
    const dev_path = try allocator.dupeZ(u8, try std.fmt.allocPrint(allocator, "{s}/dev", .{rootfs_path}));
    defer allocator.free(dev_path[0 .. dev_path.len + 1]);
    sysMount("/dev", dev_path, null, MS_BIND | MS_REC);

    // Bind mount /sys
    const sys_path = try allocator.dupeZ(u8, try std.fmt.allocPrint(allocator, "{s}/sys", .{rootfs_path}));
    defer allocator.free(sys_path[0 .. sys_path.len + 1]);
    sysMount("/sys", sys_path, null, MS_BIND | MS_REC);
}

fn cleanupMounts(allocator: std.mem.Allocator, rootfs_path: []const u8) void {
    for ([_][]const u8{ "/sys", "/dev", "/proc" }) |suffix| {
        const path = std.fmt.allocPrint(allocator, "{s}{s}", .{ rootfs_path, suffix }) catch continue;
        defer allocator.free(path);
        const path_z = allocator.dupeZ(u8, path) catch continue;
        defer allocator.free(path_z[0 .. path.len + 1]);
        sysUmount(path_z);
    }
}

fn setupDns(allocator: std.mem.Allocator, rootfs_path: []const u8) !void {
    const dst_path = try std.fmt.allocPrint(allocator, "{s}/etc/resolv.conf", .{rootfs_path});
    defer allocator.free(dst_path);

    const src = std.fs.openFileAbsolute("/etc/resolv.conf", .{}) catch return;
    defer src.close();

    const dir_path = std.fs.path.dirname(dst_path) orelse "/";
    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return;
    defer dir.close();
    var dst = dir.createFile(std.fs.path.basename(dst_path), .{}) catch return;
    defer dst.close();

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = src.readAll(&buf) catch break;
        if (n == 0) break;
        dst.writeAll(buf[0..n]) catch break;
        if (n < buf.len) break;
    }
}

test "RunError type" {
    const err: RunError = error.CommandFailed;
    _ = err;
}
