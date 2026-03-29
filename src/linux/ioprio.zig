const std = @import("std");
const linux = std.os.linux;
const log = @import("../log.zig");

const scoped_log = log.scoped("ioprio");

/// I/O scheduling class
pub const IOClass = enum(u3) {
    none = 0,
    realtime = 1,
    best_effort = 2,
    idle = 3,
};

/// I/O priority combining class and priority level
pub const IOPriority = struct {
    class: IOClass = .none,
    /// Priority level within the class (0-7, lower is higher priority)
    priority: u4 = 0,

    /// Encode into the kernel ioprio format: (class << 13) | priority
    pub fn encode(self: IOPriority) u32 {
        return (@as(u32, @intFromEnum(self.class)) << 13) | @as(u32, self.priority);
    }

    /// Decode from the kernel ioprio format
    pub fn decode(value: u32) IOPriority {
        return .{
            .class = @enumFromInt(@as(u3, @truncate(value >> 13))),
            .priority = @truncate(value & 0xf),
        };
    }
};

pub const IOPrioError = error{
    PermissionDenied,
    InvalidArgument,
    ProcessNotFound,
    Unexpected,
};

/// ioprio_set "who" constants
const IOPRIO_WHO_PROCESS: u32 = 1;
const IOPRIO_WHO_PGRP: u32 = 2;
const IOPRIO_WHO_USER: u32 = 3;

/// Set the I/O priority for a process using the ioprio_set syscall.
/// pid=0 means the current process.
pub fn setIOPriority(pid: i32, priority: IOPriority) IOPrioError!void {
    const encoded = priority.encode();
    const rc = linux.syscall3(
        .ioprio_set,
        IOPRIO_WHO_PROCESS,
        @as(u32, @bitCast(pid)),
        encoded,
    );
    return switch (linux.E.init(rc)) {
        .SUCCESS => {
            scoped_log.debug("Set IO priority: pid={d} class={} level={d}", .{
                pid, priority.class, priority.priority,
            });
        },
        .PERM, .ACCES => error.PermissionDenied,
        .INVAL => error.InvalidArgument,
        .SRCH => error.ProcessNotFound,
        else => error.Unexpected,
    };
}

/// Get the I/O priority for a process using the ioprio_get syscall.
pub fn getIOPriority(pid: i32) IOPrioError!IOPriority {
    const rc = linux.syscall2(
        .ioprio_get,
        IOPRIO_WHO_PROCESS,
        @as(u32, @bitCast(pid)),
    );
    const errno = linux.E.init(rc);
    if (errno != .SUCCESS) {
        return switch (errno) {
            .PERM, .ACCES => error.PermissionDenied,
            .INVAL => error.InvalidArgument,
            .SRCH => error.ProcessNotFound,
            else => error.Unexpected,
        };
    }
    return IOPriority.decode(@intCast(rc));
}

/// Parse an IOPriority from OCI runtime spec fields.
/// The OCI spec uses "class" (string) and "priority" (integer).
pub fn parseFromSpec(class_str: []const u8, priority_level: u4) ?IOPriority {
    const class: IOClass = if (std.mem.eql(u8, class_str, "IOPRIO_CLASS_RT"))
        .realtime
    else if (std.mem.eql(u8, class_str, "IOPRIO_CLASS_BE"))
        .best_effort
    else if (std.mem.eql(u8, class_str, "IOPRIO_CLASS_IDLE"))
        .idle
    else if (std.mem.eql(u8, class_str, "IOPRIO_CLASS_NONE"))
        .none
    else
        return null;

    return IOPriority{
        .class = class,
        .priority = priority_level,
    };
}

test "IOPriority encode/decode roundtrip" {
    const prio = IOPriority{ .class = .best_effort, .priority = 4 };
    const encoded = prio.encode();
    const decoded = IOPriority.decode(encoded);
    try std.testing.expectEqual(prio.class, decoded.class);
    try std.testing.expectEqual(prio.priority, decoded.priority);
}

test "IOPriority encode values" {
    // best_effort (2) << 13 | 4 = 16388
    const prio = IOPriority{ .class = .best_effort, .priority = 4 };
    try std.testing.expectEqual(@as(u32, (2 << 13) | 4), prio.encode());
}

test "parseFromSpec" {
    const prio = parseFromSpec("IOPRIO_CLASS_BE", 3).?;
    try std.testing.expectEqual(IOClass.best_effort, prio.class);
    try std.testing.expectEqual(@as(u4, 3), prio.priority);

    try std.testing.expect(parseFromSpec("INVALID", 0) == null);
}

test "parseFromSpec idle" {
    const prio = parseFromSpec("IOPRIO_CLASS_IDLE", 0).?;
    try std.testing.expectEqual(IOClass.idle, prio.class);
}
