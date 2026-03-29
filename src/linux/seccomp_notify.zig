const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const log = @import("../log.zig");

const scoped_log = log.scoped("seccomp_notify");

// Seccomp constants
const SECCOMP_SET_MODE_FILTER: u32 = 1;
const SECCOMP_FILTER_FLAG_NEW_LISTENER: u32 = 1 << 3;

// seccomp return values
const SECCOMP_RET_USER_NOTIF: u32 = 0x7fc00000;
const SECCOMP_RET_ALLOW: u32 = 0x7fff0000;

// BPF opcodes
const BPF_LD: u16 = 0x00;
const BPF_JMP: u16 = 0x05;
const BPF_RET: u16 = 0x06;
const BPF_W: u16 = 0x00;
const BPF_ABS: u16 = 0x20;
const BPF_JEQ: u16 = 0x10;
const BPF_K: u16 = 0x00;

// seccomp_data offsets
const SECCOMP_DATA_NR: u32 = 0;
const SECCOMP_DATA_ARCH: u32 = 4;

// Audit arch constants
const AUDIT_ARCH_X86_64: u32 = 0xC000003E;
const AUDIT_ARCH_AARCH64: u32 = 0xC00000B7;

// ioctl commands for seccomp notification
const SECCOMP_IOCTL_NOTIF_RECV: u32 = 0xC0502100;
const SECCOMP_IOCTL_NOTIF_SEND: u32 = 0xC0182101;

// BPF instruction
const SockFilter = extern struct {
    code: u16,
    jt: u8,
    jf: u8,
    k: u32,
};

const SockFilterProg = extern struct {
    len: u16,
    filter: [*]const SockFilter,
};

/// Seccomp user notification request
pub const SeccompNotifReq = extern struct {
    id: u64,
    pid: u32,
    flags: u32,
    data: SeccompData,
};

/// Seccomp data structure (matches kernel)
pub const SeccompData = extern struct {
    nr: i32,
    arch: u32,
    instruction_pointer: u64,
    args: [6]u64,
};

/// Seccomp user notification response
pub const SeccompNotifResp = extern struct {
    id: u64,
    val: i64,
    error_code: i32,
    flags: u32,
};

pub const SeccompNotifyError = error{
    FilterInstallFailed,
    NotSupported,
    ReceiveFailed,
    SendFailed,
    InvalidSyscall,
};

/// Notification handler callback type.
/// Returns true to allow the syscall, false to deny with EPERM.
pub const NotifyHandler = *const fn (req: *const SeccompNotifReq) SeccompNotifResp;

/// Install a seccomp filter with SECCOMP_RET_USER_NOTIF for the specified syscalls.
/// Returns the notification file descriptor, or an error.
pub fn installNotifyFilter(syscall_nrs: []const u32) SeccompNotifyError!i32 {
    var instructions: [256]SockFilter = undefined;
    var len: u16 = 0;

    // Load architecture
    instructions[len] = .{ .code = BPF_LD | BPF_W | BPF_ABS, .jt = 0, .jf = 0, .k = SECCOMP_DATA_ARCH };
    len += 1;

    // Check architecture
    const expected_arch = comptime getAuditArch();
    instructions[len] = .{ .code = BPF_JMP | BPF_JEQ | BPF_K, .jt = 1, .jf = 0, .k = expected_arch };
    len += 1;

    // Kill on arch mismatch
    instructions[len] = .{ .code = BPF_RET | BPF_K, .jt = 0, .jf = 0, .k = 0x80000000 }; // SECCOMP_RET_KILL_PROCESS
    len += 1;

    // Load syscall number
    instructions[len] = .{ .code = BPF_LD | BPF_W | BPF_ABS, .jt = 0, .jf = 0, .k = SECCOMP_DATA_NR };
    len += 1;

    // For each syscall: if match, return USER_NOTIF
    for (syscall_nrs) |nr| {
        if (len + 2 >= instructions.len) break;
        instructions[len] = .{ .code = BPF_JMP | BPF_JEQ | BPF_K, .jt = 0, .jf = 1, .k = nr };
        len += 1;
        instructions[len] = .{ .code = BPF_RET | BPF_K, .jt = 0, .jf = 0, .k = SECCOMP_RET_USER_NOTIF };
        len += 1;
    }

    // Default: allow
    instructions[len] = .{ .code = BPF_RET | BPF_K, .jt = 0, .jf = 0, .k = SECCOMP_RET_ALLOW };
    len += 1;

    const prog = SockFilterProg{
        .len = len,
        .filter = &instructions,
    };

    // Use seccomp() syscall with SECCOMP_FILTER_FLAG_NEW_LISTENER
    const rc = linux.syscall3(
        .seccomp,
        SECCOMP_SET_MODE_FILTER,
        SECCOMP_FILTER_FLAG_NEW_LISTENER,
        @intFromPtr(&prog),
    );
    const errno = linux.E.init(rc);
    if (errno != .SUCCESS) {
        if (errno == .NOSYS or errno == .INVAL) {
            scoped_log.warn("Seccomp user notification not supported", .{});
            return error.NotSupported;
        }
        scoped_log.warn("Failed to install seccomp notify filter: {}", .{errno});
        return error.FilterInstallFailed;
    }

    const notify_fd: i32 = @intCast(rc);
    scoped_log.debug("Installed seccomp notify filter, fd={d}", .{notify_fd});
    return notify_fd;
}

/// Process seccomp user notifications in a loop.
/// Reads notifications from notify_fd and dispatches to the handler callback.
/// Returns when the fd is closed or an error occurs.
pub fn handleNotifications(notify_fd: i32, handler: NotifyHandler) SeccompNotifyError!void {
    while (true) {
        var req: SeccompNotifReq = std.mem.zeroes(SeccompNotifReq);

        // SECCOMP_IOCTL_NOTIF_RECV
        const recv_rc = linux.syscall3(
            .ioctl,
            @intCast(notify_fd),
            SECCOMP_IOCTL_NOTIF_RECV,
            @intFromPtr(&req),
        );
        const recv_errno = linux.E.init(recv_rc);
        if (recv_errno != .SUCCESS) {
            if (recv_errno == .BADF or recv_errno == .NOENT) {
                // fd closed or process gone, exit gracefully
                scoped_log.debug("Notification fd closed, exiting handler loop", .{});
                return;
            }
            scoped_log.warn("Failed to receive seccomp notification: {}", .{recv_errno});
            return error.ReceiveFailed;
        }

        // Call the handler
        const resp = handler(&req);

        // SECCOMP_IOCTL_NOTIF_SEND
        const send_rc = linux.syscall3(
            .ioctl,
            @intCast(notify_fd),
            SECCOMP_IOCTL_NOTIF_SEND,
            @intFromPtr(&resp),
        );
        const send_errno = linux.E.init(send_rc);
        if (send_errno != .SUCCESS) {
            if (send_errno == .BADF or send_errno == .NOENT) {
                return;
            }
            scoped_log.warn("Failed to send seccomp notification response: {}", .{send_errno});
            return error.SendFailed;
        }
    }
}

/// Create a response that allows the syscall to proceed.
pub fn allowResponse(req_id: u64) SeccompNotifResp {
    return .{
        .id = req_id,
        .val = 0,
        .error_code = 0,
        .flags = 1, // SECCOMP_USER_NOTIF_FLAG_CONTINUE
    };
}

/// Create a response that denies the syscall with the given errno.
pub fn denyResponse(req_id: u64, err: i32) SeccompNotifResp {
    return .{
        .id = req_id,
        .val = 0,
        .error_code = -err,
        .flags = 0,
    };
}

fn getAuditArch() u32 {
    return switch (builtin.cpu.arch) {
        .x86_64 => AUDIT_ARCH_X86_64,
        .aarch64 => AUDIT_ARCH_AARCH64,
        else => AUDIT_ARCH_X86_64,
    };
}

test "SeccompNotifReq layout" {
    // Ensure the struct is usable
    var req = std.mem.zeroes(SeccompNotifReq);
    req.id = 42;
    req.pid = 1000;
    try std.testing.expectEqual(@as(u64, 42), req.id);
    try std.testing.expectEqual(@as(u32, 1000), req.pid);
}

test "allowResponse" {
    const resp = allowResponse(123);
    try std.testing.expectEqual(@as(u64, 123), resp.id);
    try std.testing.expectEqual(@as(u32, 1), resp.flags);
    try std.testing.expectEqual(@as(i32, 0), resp.error_code);
}

test "denyResponse" {
    const resp = denyResponse(456, 1); // EPERM
    try std.testing.expectEqual(@as(u64, 456), resp.id);
    try std.testing.expectEqual(@as(i32, -1), resp.error_code);
    try std.testing.expectEqual(@as(u32, 0), resp.flags);
}
