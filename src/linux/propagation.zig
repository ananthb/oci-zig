const std = @import("std");
const log = @import("../log.zig");
const syscall = @import("syscall.zig");

const scoped_log = log.scoped("propagation");

/// Mount propagation types as defined by the Linux kernel.
pub const Propagation = enum(u32) {
    private = syscall.MS_PRIVATE,
    shared = syscall.MS_SHARED,
    slave = syscall.MS_SLAVE,
    unbindable = syscall.MS_UNBINDABLE,
    rprivate = syscall.MS_PRIVATE | syscall.MS_REC,
    rshared = syscall.MS_SHARED | syscall.MS_REC,
    rslave = syscall.MS_SLAVE | syscall.MS_REC,
    runbindable = syscall.MS_UNBINDABLE | syscall.MS_REC,
};

pub const PropagationError = error{
    InvalidOption,
    PathTooLong,
    SetFailed,
};

/// Apply a mount propagation setting to a path.
pub fn setPropagation(path: []const u8, propagation: Propagation) PropagationError!void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;

    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(path_buf[0..path.len :0]);

    const flags = @intFromEnum(propagation);
    const mount_flags = syscall.MountFlags{
        .private = (flags & syscall.MS_PRIVATE) != 0,
        .shared = (flags & syscall.MS_SHARED) != 0,
        .slave = (flags & syscall.MS_SLAVE) != 0,
        .unbindable = (flags & syscall.MS_UNBINDABLE) != 0,
        .rec = (flags & syscall.MS_REC) != 0,
    };

    syscall.mount(null, path_z, null, mount_flags, null) catch {
        scoped_log.warn("Failed to set propagation on {s}", .{path});
        return error.SetFailed;
    };

    scoped_log.debug("Set propagation on {s} to {}", .{ path, propagation });
}

/// Parse an OCI mount propagation option string into a Propagation value.
/// Recognizes: "private", "shared", "slave", "unbindable" and their
/// recursive variants "rprivate", "rshared", "rslave", "runbindable".
pub fn parsePropagation(options: []const []const u8) ?Propagation {
    // Return the last propagation option found (OCI spec: last wins)
    var result: ?Propagation = null;
    for (options) |opt| {
        if (std.mem.eql(u8, opt, "private")) {
            result = .private;
        } else if (std.mem.eql(u8, opt, "rprivate")) {
            result = .rprivate;
        } else if (std.mem.eql(u8, opt, "shared")) {
            result = .shared;
        } else if (std.mem.eql(u8, opt, "rshared")) {
            result = .rshared;
        } else if (std.mem.eql(u8, opt, "slave")) {
            result = .slave;
        } else if (std.mem.eql(u8, opt, "rslave")) {
            result = .rslave;
        } else if (std.mem.eql(u8, opt, "unbindable")) {
            result = .unbindable;
        } else if (std.mem.eql(u8, opt, "runbindable")) {
            result = .runbindable;
        }
    }
    return result;
}

/// Convert a Propagation value to its OCI option string.
pub fn propagationToString(prop: Propagation) []const u8 {
    return switch (prop) {
        .private => "private",
        .shared => "shared",
        .slave => "slave",
        .unbindable => "unbindable",
        .rprivate => "rprivate",
        .rshared => "rshared",
        .rslave => "rslave",
        .runbindable => "runbindable",
    };
}

test "parsePropagation basic" {
    const opts = [_][]const u8{ "bind", "rprivate" };
    try std.testing.expectEqual(Propagation.rprivate, parsePropagation(&opts).?);
}

test "parsePropagation last wins" {
    const opts = [_][]const u8{ "rprivate", "rshared" };
    try std.testing.expectEqual(Propagation.rshared, parsePropagation(&opts).?);
}

test "parsePropagation no match" {
    const opts = [_][]const u8{ "bind", "ro" };
    try std.testing.expect(parsePropagation(&opts) == null);
}

test "propagationToString roundtrip" {
    try std.testing.expectEqualStrings("rprivate", propagationToString(.rprivate));
    try std.testing.expectEqualStrings("shared", propagationToString(.shared));
}
