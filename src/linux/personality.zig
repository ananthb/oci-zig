const std = @import("std");
const linux = std.os.linux;
const log = @import("../log.zig");

const scoped_log = log.scoped("personality");

/// Linux execution domain / personality flags
pub const Domain = enum(u32) {
    /// Default Linux personality
    linux = 0x00000000,
    /// 32-bit compatibility mode (ADDR_LIMIT_32BIT + SHORT_INODE + WHOLE_SECONDS + STICKY_TIMEOUTS)
    linux32 = 0x00000008,

    pub fn fromName(name: []const u8) ?Domain {
        if (std.ascii.eqlIgnoreCase(name, "LINUX")) return .linux;
        if (std.ascii.eqlIgnoreCase(name, "LINUX32")) return .linux32;
        return null;
    }

    pub fn toName(self: Domain) []const u8 {
        return switch (self) {
            .linux => "LINUX",
            .linux32 => "LINUX32",
        };
    }
};

pub const PersonalityError = error{
    PermissionDenied,
    InvalidArgument,
    Unexpected,
};

/// Set the process execution domain / personality via the personality() syscall.
pub fn setPersonality(domain: Domain) PersonalityError!void {
    const rc = linux.syscall1(.personality, @intFromEnum(domain));
    const errno = linux.E.init(rc);
    if (errno != .SUCCESS) {
        return switch (errno) {
            .PERM => error.PermissionDenied,
            .INVAL => error.InvalidArgument,
            else => error.Unexpected,
        };
    }
    scoped_log.debug("Set personality to {s}", .{domain.toName()});
}

/// Get the current process personality.
pub fn getPersonality() PersonalityError!Domain {
    // personality(0xffffffff) returns current personality without changing it
    const rc = linux.syscall1(.personality, 0xffffffff);
    const errno = linux.E.init(rc);
    if (errno != .SUCCESS) {
        return switch (errno) {
            .PERM => error.PermissionDenied,
            .INVAL => error.InvalidArgument,
            else => error.Unexpected,
        };
    }
    // Only match known domains, treat others as linux default
    return std.meta.intToEnum(Domain, @as(u32, @truncate(rc))) catch .linux;
}

/// Parse a personality from an OCI runtime spec string.
pub fn parsePersonality(name: []const u8) ?Domain {
    return Domain.fromName(name);
}

test "Domain.fromName" {
    try std.testing.expectEqual(Domain.linux, Domain.fromName("LINUX").?);
    try std.testing.expectEqual(Domain.linux32, Domain.fromName("LINUX32").?);
    try std.testing.expectEqual(Domain.linux32, Domain.fromName("linux32").?);
    try std.testing.expect(Domain.fromName("UNKNOWN") == null);
}

test "Domain.toName" {
    try std.testing.expectEqualStrings("LINUX", Domain.linux.toName());
    try std.testing.expectEqualStrings("LINUX32", Domain.linux32.toName());
}

test "Domain enum values" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(Domain.linux));
    try std.testing.expectEqual(@as(u32, 0x00000008), @intFromEnum(Domain.linux32));
}
