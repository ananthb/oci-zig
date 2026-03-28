const std = @import("std");
const linux = std.os.linux;
const log = @import("../log.zig");

const scoped_log = log.scoped("caps");

/// Linux capability constants
pub const CAP = struct {
    pub const CHOWN: u6 = 0;
    pub const DAC_OVERRIDE: u6 = 1;
    pub const DAC_READ_SEARCH: u6 = 2;
    pub const FOWNER: u6 = 3;
    pub const FSETID: u6 = 4;
    pub const KILL: u6 = 5;
    pub const SETGID: u6 = 6;
    pub const SETUID: u6 = 7;
    pub const SETPCAP: u6 = 8;
    pub const LINUX_IMMUTABLE: u6 = 9;
    pub const NET_BIND_SERVICE: u6 = 10;
    pub const NET_BROADCAST: u6 = 11;
    pub const NET_ADMIN: u6 = 12;
    pub const NET_RAW: u6 = 13;
    pub const IPC_LOCK: u6 = 14;
    pub const IPC_OWNER: u6 = 15;
    pub const SYS_MODULE: u6 = 16;
    pub const SYS_RAWIO: u6 = 17;
    pub const SYS_CHROOT: u6 = 18;
    pub const SYS_PTRACE: u6 = 19;
    pub const SYS_PACCT: u6 = 20;
    pub const SYS_ADMIN: u6 = 21;
    pub const SYS_BOOT: u6 = 22;
    pub const SYS_NICE: u6 = 23;
    pub const SYS_RESOURCE: u6 = 24;
    pub const SYS_TIME: u6 = 25;
    pub const SYS_TTY_CONFIG: u6 = 26;
    pub const MKNOD: u6 = 27;
    pub const LEASE: u6 = 28;
    pub const AUDIT_WRITE: u6 = 29;
    pub const AUDIT_CONTROL: u6 = 30;
    pub const SETFCAP: u6 = 31;
    pub const MAC_OVERRIDE: u6 = 32;
    pub const MAC_ADMIN: u6 = 33;
    pub const SYSLOG: u6 = 34;
    pub const WAKE_ALARM: u6 = 35;
    pub const BLOCK_SUSPEND: u6 = 36;
    pub const AUDIT_READ: u6 = 37;
    pub const PERFMON: u6 = 38;
    pub const BPF: u6 = 39;
    pub const CHECKPOINT_RESTORE: u6 = 40;
    pub const LAST: u6 = 40;
};

/// Default capabilities for an OCI container (same as Docker default)
pub const default_caps = [_]u6{
    CAP.CHOWN,
    CAP.DAC_OVERRIDE,
    CAP.FSETID,
    CAP.FOWNER,
    CAP.MKNOD,
    CAP.NET_RAW,
    CAP.SETGID,
    CAP.SETUID,
    CAP.SETFCAP,
    CAP.SETPCAP,
    CAP.NET_BIND_SERVICE,
    CAP.SYS_CHROOT,
    CAP.KILL,
    CAP.AUDIT_WRITE,
};

/// Capability set as a bitmask
pub const CapSet = struct {
    bits: u64 = 0,

    pub fn add(self: *CapSet, cap: u6) void {
        self.bits |= @as(u64, 1) << cap;
    }

    pub fn remove(self: *CapSet, cap: u6) void {
        self.bits &= ~(@as(u64, 1) << cap);
    }

    pub fn has(self: *const CapSet, cap: u6) bool {
        return (self.bits & (@as(u64, 1) << cap)) != 0;
    }

    /// Create from a list of capability numbers
    pub fn fromList(caps: []const u6) CapSet {
        var set = CapSet{};
        for (caps) |cap| set.add(cap);
        return set;
    }

    /// Create the default OCI container capability set
    pub fn defaultSet() CapSet {
        return fromList(&default_caps);
    }

    /// Create from OCI capability name strings (e.g. "CAP_NET_RAW")
    pub fn fromNames(names: []const []const u8) CapSet {
        var set = CapSet{};
        for (names) |name| {
            if (capFromName(name)) |cap| {
                set.add(cap);
            }
        }
        return set;
    }
};

/// capget/capset data structures
const CapUserHeader = extern struct {
    version: u32,
    pid: i32,
};

const CapUserData = extern struct {
    effective: u32,
    permitted: u32,
    inheritable: u32,
};

const CAP_V3: u32 = 0x20080522;

/// Apply a capability set to the current process.
/// Drops all capabilities not in the set.
pub fn applyCaps(caps: CapSet) !void {
    // PR_SET_KEEPCAPS so caps survive setuid
    _ = linux.syscall2(.prctl, 8, 1); // PR_SET_KEEPCAPS = 8

    // Set bounding set: drop caps not in our set
    var cap: u6 = 0;
    while (cap <= CAP.LAST) : (cap += 1) {
        if (!caps.has(cap)) {
            // PR_CAPBSET_DROP = 24
            _ = linux.syscall2(.prctl, 24, cap);
        }
    }

    // Set effective, permitted, inheritable via capset
    const lo: u32 = @truncate(caps.bits);
    const hi: u32 = @truncate(caps.bits >> 32);

    var hdr = CapUserHeader{ .version = CAP_V3, .pid = 0 };
    var data = [2]CapUserData{
        .{ .effective = lo, .permitted = lo, .inheritable = lo },
        .{ .effective = hi, .permitted = hi, .inheritable = hi },
    };

    const rc = linux.syscall2(.capset, @intFromPtr(&hdr), @intFromPtr(&data));
    if (linux.E.init(rc) != .SUCCESS) {
        scoped_log.warn("capset failed", .{});
        return error.CapsetFailed;
    }

    // Set ambient caps for each cap in the set
    cap = 0;
    while (cap <= CAP.LAST) : (cap += 1) {
        if (caps.has(cap)) {
            // PR_CAP_AMBIENT = 47, PR_CAP_AMBIENT_RAISE = 2
            _ = linux.syscall3(.prctl, 47, 2, cap);
        }
    }

    // Clear PR_SET_KEEPCAPS
    _ = linux.syscall2(.prctl, 8, 0);

    scoped_log.debug("Applied capability set: 0x{x}", .{caps.bits});
}

/// Set PR_SET_NO_NEW_PRIVS
pub fn setNoNewPrivs() void {
    // PR_SET_NO_NEW_PRIVS = 38
    _ = linux.syscall2(.prctl, 38, 1);
}

/// Parse a capability name like "CAP_NET_RAW" to its number
pub fn capFromName(name: []const u8) ?u6 {
    const stripped = if (std.mem.startsWith(u8, name, "CAP_")) name[4..] else name;
    const map = .{
        .{ "CHOWN", CAP.CHOWN },
        .{ "DAC_OVERRIDE", CAP.DAC_OVERRIDE },
        .{ "DAC_READ_SEARCH", CAP.DAC_READ_SEARCH },
        .{ "FOWNER", CAP.FOWNER },
        .{ "FSETID", CAP.FSETID },
        .{ "KILL", CAP.KILL },
        .{ "SETGID", CAP.SETGID },
        .{ "SETUID", CAP.SETUID },
        .{ "SETPCAP", CAP.SETPCAP },
        .{ "LINUX_IMMUTABLE", CAP.LINUX_IMMUTABLE },
        .{ "NET_BIND_SERVICE", CAP.NET_BIND_SERVICE },
        .{ "NET_BROADCAST", CAP.NET_BROADCAST },
        .{ "NET_ADMIN", CAP.NET_ADMIN },
        .{ "NET_RAW", CAP.NET_RAW },
        .{ "IPC_LOCK", CAP.IPC_LOCK },
        .{ "IPC_OWNER", CAP.IPC_OWNER },
        .{ "SYS_MODULE", CAP.SYS_MODULE },
        .{ "SYS_RAWIO", CAP.SYS_RAWIO },
        .{ "SYS_CHROOT", CAP.SYS_CHROOT },
        .{ "SYS_PTRACE", CAP.SYS_PTRACE },
        .{ "SYS_PACCT", CAP.SYS_PACCT },
        .{ "SYS_ADMIN", CAP.SYS_ADMIN },
        .{ "SYS_BOOT", CAP.SYS_BOOT },
        .{ "SYS_NICE", CAP.SYS_NICE },
        .{ "SYS_RESOURCE", CAP.SYS_RESOURCE },
        .{ "SYS_TIME", CAP.SYS_TIME },
        .{ "SYS_TTY_CONFIG", CAP.SYS_TTY_CONFIG },
        .{ "MKNOD", CAP.MKNOD },
        .{ "LEASE", CAP.LEASE },
        .{ "AUDIT_WRITE", CAP.AUDIT_WRITE },
        .{ "AUDIT_CONTROL", CAP.AUDIT_CONTROL },
        .{ "SETFCAP", CAP.SETFCAP },
        .{ "MAC_OVERRIDE", CAP.MAC_OVERRIDE },
        .{ "MAC_ADMIN", CAP.MAC_ADMIN },
        .{ "SYSLOG", CAP.SYSLOG },
        .{ "WAKE_ALARM", CAP.WAKE_ALARM },
        .{ "BLOCK_SUSPEND", CAP.BLOCK_SUSPEND },
        .{ "AUDIT_READ", CAP.AUDIT_READ },
        .{ "PERFMON", CAP.PERFMON },
        .{ "BPF", CAP.BPF },
        .{ "CHECKPOINT_RESTORE", CAP.CHECKPOINT_RESTORE },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, stripped, entry[0])) return entry[1];
    }
    return null;
}

test "CapSet operations" {
    var set = CapSet{};
    try std.testing.expect(!set.has(CAP.NET_RAW));
    set.add(CAP.NET_RAW);
    try std.testing.expect(set.has(CAP.NET_RAW));
    set.remove(CAP.NET_RAW);
    try std.testing.expect(!set.has(CAP.NET_RAW));
}

test "default caps" {
    const set = CapSet.defaultSet();
    try std.testing.expect(set.has(CAP.CHOWN));
    try std.testing.expect(set.has(CAP.NET_RAW));
    try std.testing.expect(set.has(CAP.KILL));
    try std.testing.expect(!set.has(CAP.SYS_ADMIN));
    try std.testing.expect(!set.has(CAP.SYS_MODULE));
}

test "capFromName" {
    try std.testing.expectEqual(CAP.NET_RAW, capFromName("CAP_NET_RAW").?);
    try std.testing.expectEqual(CAP.SYS_ADMIN, capFromName("SYS_ADMIN").?);
    try std.testing.expect(capFromName("INVALID_CAP") == null);
}
