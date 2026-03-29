const std = @import("std");
const linux = std.os.linux;
const log = @import("../log.zig");
const syscall = @import("syscall.zig");

const scoped_log = log.scoped("console");

pub const ConsoleError = error{
    OpenPtmxFailed,
    GrantptFailed,
    UnlockptFailed,
    PtsnFailed,
    SocketFailed,
    ConnectFailed,
    SendFailed,
    ReceiveFailed,
    SetupFailed,
    PathTooLong,
};

/// Result of opening a pseudo-terminal pair
pub const PtyPair = struct {
    master_fd: i32,
    slave_fd: i32,
    slave_path: [64]u8,
    slave_path_len: usize,

    pub fn slaveName(self: *const PtyPair) []const u8 {
        return self.slave_path[0..self.slave_path_len];
    }
};

/// TIOCGPTN ioctl number - get pty number
const TIOCGPTN: u32 = 0x80045430;

/// TIOCSPTLCK ioctl number - lock/unlock pty
const TIOCSPTLCK: u32 = 0x40045431;

/// Open a pseudo-terminal master/slave pair using raw syscalls.
/// Opens /dev/ptmx, unlocks the slave, and opens the slave device.
pub fn openPseudoTerminal() ConsoleError!PtyPair {
    // Open /dev/ptmx
    const O_RDWR: u32 = 0o2;
    const O_NOCTTY: u32 = 0o400;
    const O_CLOEXEC: u32 = 0o2000000;

    const ptmx_path = "/dev/ptmx";
    const master_rc = linux.syscall4(
        .openat,
        @bitCast(@as(isize, -100)), // AT_FDCWD
        @intFromPtr(@as([*:0]const u8, ptmx_path)),
        O_RDWR | O_NOCTTY | O_CLOEXEC,
        0,
    );
    if (linux.E.init(master_rc) != .SUCCESS) {
        scoped_log.warn("Failed to open /dev/ptmx", .{});
        return error.OpenPtmxFailed;
    }
    const master_fd: i32 = @intCast(master_rc);

    // Unlock the slave (TIOCSPTLCK with value 0)
    var unlock: i32 = 0;
    const unlock_rc = linux.syscall3(
        .ioctl,
        @intCast(master_fd),
        TIOCSPTLCK,
        @intFromPtr(&unlock),
    );
    if (linux.E.init(unlock_rc) != .SUCCESS) {
        _ = linux.syscall1(.close, @intCast(master_fd));
        scoped_log.warn("Failed to unlock pty slave", .{});
        return error.UnlockptFailed;
    }

    // Get the pty number (TIOCGPTN)
    var pty_num: u32 = 0;
    const ptn_rc = linux.syscall3(
        .ioctl,
        @intCast(master_fd),
        TIOCGPTN,
        @intFromPtr(&pty_num),
    );
    if (linux.E.init(ptn_rc) != .SUCCESS) {
        _ = linux.syscall1(.close, @intCast(master_fd));
        scoped_log.warn("Failed to get pty number", .{});
        return error.PtsnFailed;
    }

    // Build slave path: /dev/pts/<N>
    var slave_path: [64]u8 = undefined;
    const slave_name = std.fmt.bufPrint(&slave_path, "/dev/pts/{d}", .{pty_num}) catch {
        _ = linux.syscall1(.close, @intCast(master_fd));
        return error.PtsnFailed;
    };
    // Null-terminate for syscall
    slave_path[slave_name.len] = 0;

    // Open the slave device
    const slave_rc = linux.syscall4(
        .openat,
        @bitCast(@as(isize, -100)), // AT_FDCWD
        @intFromPtr(@as([*:0]const u8, @ptrCast(slave_path[0..slave_name.len :0]))),
        O_RDWR | O_NOCTTY | O_CLOEXEC,
        0,
    );
    if (linux.E.init(slave_rc) != .SUCCESS) {
        _ = linux.syscall1(.close, @intCast(master_fd));
        scoped_log.warn("Failed to open pty slave {s}", .{slave_name});
        return error.OpenPtmxFailed;
    }
    const slave_fd: i32 = @intCast(slave_rc);

    scoped_log.debug("Opened pty pair: master={d}, slave={d} ({s})", .{ master_fd, slave_fd, slave_name });

    return PtyPair{
        .master_fd = master_fd,
        .slave_fd = slave_fd,
        .slave_path = slave_path,
        .slave_path_len = slave_name.len,
    };
}

/// Unix socket address structure
const SockaddrUn = extern struct {
    family: u16 = std.os.linux.AF.UNIX,
    path: [108]u8 = [_]u8{0} ** 108,
};

/// Send a file descriptor over a Unix domain socket using SCM_RIGHTS.
pub fn sendFdOverSocket(socket_path: []const u8, fd: i32) ConsoleError!void {
    if (socket_path.len >= 108) return error.PathTooLong;

    // Create a Unix socket
    const sock_rc = linux.syscall3(
        .socket,
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
    );
    if (linux.E.init(sock_rc) != .SUCCESS) {
        scoped_log.warn("Failed to create unix socket", .{});
        return error.SocketFailed;
    }
    const sock_fd: i32 = @intCast(sock_rc);
    defer _ = linux.syscall1(.close, @intCast(sock_fd));

    // Connect to the socket path
    var addr = SockaddrUn{};
    @memcpy(addr.path[0..socket_path.len], socket_path);

    const connect_rc = linux.syscall3(
        .connect,
        @intCast(sock_fd),
        @intFromPtr(&addr),
        @as(u32, @intCast(@sizeOf(u16) + socket_path.len + 1)),
    );
    if (linux.E.init(connect_rc) != .SUCCESS) {
        scoped_log.warn("Failed to connect to {s}", .{socket_path});
        return error.ConnectFailed;
    }

    // Build cmsg with SCM_RIGHTS
    const SCM_RIGHTS: i32 = 1;
    const cmsg_space = cmsghdr_size + @sizeOf(i32);
    // Align to 8 bytes
    const aligned_space = (cmsg_space + 7) & ~@as(usize, 7);
    var cmsg_buf: [aligned_space + 64]u8 align(8) = [_]u8{0} ** (aligned_space + 64);

    const cmsg: *Cmsghdr = @ptrCast(@alignCast(&cmsg_buf));
    cmsg.len = cmsg_space;
    cmsg.level = linux.SOL.SOCKET;
    cmsg.type = SCM_RIGHTS;
    // Write the fd into the cmsg data area
    const data_ptr: *i32 = @ptrCast(@alignCast(cmsg_buf[cmsghdr_size..]));
    data_ptr.* = fd;

    // A single byte of data is required
    var iov_data: [1]u8 = .{0};
    var iov = IoVec{
        .base = &iov_data,
        .len = 1,
    };

    var msg = Msghdr{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&iov),
        .iovlen = 1,
        .control = &cmsg_buf,
        .controllen = aligned_space,
        .flags = 0,
    };

    const send_rc = linux.syscall3(
        .sendmsg,
        @intCast(sock_fd),
        @intFromPtr(&msg),
        0,
    );
    if (linux.E.init(send_rc) != .SUCCESS) {
        scoped_log.warn("Failed to send fd over socket", .{});
        return error.SendFailed;
    }

    scoped_log.debug("Sent fd {d} over socket {s}", .{ fd, socket_path });
}

/// Receive a file descriptor from a Unix domain socket using SCM_RIGHTS.
pub fn receiveFdFromSocket(listen_fd: i32) ConsoleError!i32 {
    const SCM_RIGHTS: i32 = 1;
    const cmsg_space = cmsghdr_size + @sizeOf(i32);
    const aligned_space = (cmsg_space + 7) & ~@as(usize, 7);
    var cmsg_buf: [aligned_space + 64]u8 align(8) = [_]u8{0} ** (aligned_space + 64);

    var iov_data: [1]u8 = .{0};
    var iov = IoVec{
        .base = &iov_data,
        .len = 1,
    };

    var msg = Msghdr{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&iov),
        .iovlen = 1,
        .control = &cmsg_buf,
        .controllen = aligned_space,
        .flags = 0,
    };

    const recv_rc = linux.syscall3(
        .recvmsg,
        @intCast(listen_fd),
        @intFromPtr(&msg),
        0,
    );
    if (linux.E.init(recv_rc) != .SUCCESS) {
        scoped_log.warn("Failed to receive fd from socket", .{});
        return error.ReceiveFailed;
    }

    // Extract the fd from cmsg
    const cmsg: *const Cmsghdr = @ptrCast(@alignCast(&cmsg_buf));
    if (cmsg.level == linux.SOL.SOCKET and cmsg.type == SCM_RIGHTS) {
        const fd_ptr: *const i32 = @ptrCast(@alignCast(cmsg_buf[cmsghdr_size..]));
        scoped_log.debug("Received fd {d} from socket", .{fd_ptr.*});
        return fd_ptr.*;
    }

    scoped_log.warn("No SCM_RIGHTS message received", .{});
    return error.ReceiveFailed;
}

/// Full console setup flow for a container.
/// Opens a PTY, sends the master fd over the console socket, and returns the slave fd
/// for use as the container's console.
pub fn setupConsoleSocket(rootfs_path: []const u8, console_socket_path: []const u8) ConsoleError!i32 {
    _ = rootfs_path;

    // Open a new PTY pair
    const pty = try openPseudoTerminal();

    // Send the master fd to the runtime caller via the console socket
    sendFdOverSocket(console_socket_path, pty.master_fd) catch |err| {
        _ = linux.syscall1(.close, @intCast(pty.master_fd));
        _ = linux.syscall1(.close, @intCast(pty.slave_fd));
        scoped_log.warn("Failed to send console master fd: {}", .{err});
        return error.SetupFailed;
    };

    // Close the master fd - the caller on the other end of the socket now owns it
    _ = linux.syscall1(.close, @intCast(pty.master_fd));

    scoped_log.debug("Console setup complete, slave fd={d}", .{pty.slave_fd});
    return pty.slave_fd;
}

// --- Internal types for sendmsg/recvmsg ---

const cmsghdr_size = @sizeOf(Cmsghdr);

const Cmsghdr = extern struct {
    len: usize,
    level: i32,
    type: i32,
};

const IoVec = extern struct {
    base: [*]u8,
    len: usize,
};

const Msghdr = extern struct {
    name: ?*anyopaque,
    namelen: u32,
    iov: [*]IoVec,
    iovlen: usize,
    control: ?*anyopaque,
    controllen: usize,
    flags: i32,
};

test "PtyPair slaveName" {
    var pair = PtyPair{
        .master_fd = 3,
        .slave_fd = 4,
        .slave_path = undefined,
        .slave_path_len = 10,
    };
    @memcpy(pair.slave_path[0..10], "/dev/pts/0");
    try std.testing.expectEqualStrings("/dev/pts/0", pair.slaveName());
}

test "SockaddrUn layout" {
    const addr = SockaddrUn{};
    try std.testing.expectEqual(@as(u16, linux.AF.UNIX), addr.family);
    try std.testing.expectEqual(@as(u8, 0), addr.path[0]);
}
