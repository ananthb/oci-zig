const std = @import("std");
const log = @import("../log.zig");

const scoped_log = log.scoped("cgroup");

pub const CgroupError = error{
    NotSupported,
    CreateFailed,
    WriteFailed,
    MoveFailed,
    OutOfMemory,
};

/// Resource limits for a container
pub const Resources = struct {
    /// Memory limit in bytes (0 = unlimited)
    memory_max: u64 = 0,
    /// Memory + swap limit in bytes (0 = unlimited)
    memory_swap_max: u64 = 0,
    /// CPU quota in microseconds per period (0 = unlimited)
    /// e.g. 50000 with period 100000 = 50% of one CPU
    cpu_quota: u64 = 0,
    /// CPU period in microseconds (default: 100000 = 100ms)
    cpu_period: u64 = 100000,
    /// CPU weight (1-10000, default 100, maps to shares)
    cpu_weight: u32 = 100,
    /// Max number of PIDs (0 = unlimited)
    pids_max: u32 = 0,
    /// CPUs to use (e.g. "0-3" or "0,2"), null = all
    cpuset: ?[]const u8 = null,
};

/// A cgroup v2 scope for a container
pub const Cgroup = struct {
    path: []const u8,
    allocator: std.mem.Allocator,

    /// Create a cgroup for a container under /sys/fs/cgroup/<prefix>/<id>
    pub fn create(allocator: std.mem.Allocator, prefix: []const u8, id: []const u8) CgroupError!Cgroup {
        // Verify cgroup v2 is mounted
        std.fs.accessAbsolute("/sys/fs/cgroup/cgroup.controllers", .{}) catch {
            scoped_log.warn("cgroup v2 not available", .{});
            return error.NotSupported;
        };

        const path = std.fmt.allocPrint(allocator, "/sys/fs/cgroup/{s}/{s}", .{ prefix, id }) catch
            return error.OutOfMemory;
        errdefer allocator.free(path);

        // Create the cgroup directory
        {
            var root = std.fs.openDirAbsolute("/sys/fs/cgroup", .{}) catch return error.CreateFailed;
            defer root.close();
            const rel = std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, id }) catch return error.OutOfMemory;
            defer allocator.free(rel);
            root.makePath(rel) catch return error.CreateFailed;
        }

        // Enable controllers in the parent
        enableControllers(allocator, prefix) catch {};

        scoped_log.debug("Created cgroup at {s}", .{path});
        return Cgroup{ .path = path, .allocator = allocator };
    }

    /// Apply resource limits
    pub fn setResources(self: *const Cgroup, resources: *const Resources) void {
        if (resources.memory_max > 0) {
            writeU64(self.path, "memory.max", resources.memory_max);
        }
        if (resources.memory_swap_max > 0) {
            writeU64(self.path, "memory.swap.max", resources.memory_swap_max);
        }
        if (resources.cpu_quota > 0) {
            writeCpuMax(self.path, resources.cpu_quota, resources.cpu_period);
        }
        if (resources.cpu_weight > 0 and resources.cpu_weight != 100) {
            writeU64(self.path, "cpu.weight", resources.cpu_weight);
        }
        if (resources.pids_max > 0) {
            writeU64(self.path, "pids.max", resources.pids_max);
        }
        if (resources.cpuset) |cpus| {
            writeStr(self.path, "cpuset.cpus", cpus);
        }
    }

    /// Move a process into this cgroup
    pub fn addProcess(self: *const Cgroup, pid: i32) CgroupError!void {
        var buf: [32]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch return error.WriteFailed;
        writeStr(self.path, "cgroup.procs", pid_str);
    }

    /// Remove the cgroup directory (must have no processes)
    pub fn destroy(self: *Cgroup) void {
        std.fs.deleteTreeAbsolute(self.path) catch |err| {
            scoped_log.debug("Cannot remove cgroup {s}: {}", .{ self.path, err });
        };
        self.allocator.free(self.path);
    }

    /// Freeze all processes in this cgroup
    pub fn freeze(self: *const Cgroup) void {
        writeStr(self.path, "cgroup.freeze", "1");
    }

    /// Thaw all processes in this cgroup
    pub fn thaw(self: *const Cgroup) void {
        writeStr(self.path, "cgroup.freeze", "0");
    }

    /// Kill all processes in this cgroup
    pub fn kill(self: *const Cgroup) void {
        writeStr(self.path, "cgroup.kill", "1");
    }

    /// Read current memory usage
    pub fn memoryUsage(self: *const Cgroup) ?u64 {
        return readU64(self.path, "memory.current");
    }

    /// Read current number of PIDs
    pub fn pidsCount(self: *const Cgroup) ?u64 {
        return readU64(self.path, "pids.current");
    }
};

/// Enable all available controllers in a parent cgroup
fn enableControllers(allocator: std.mem.Allocator, parent: []const u8) !void {
    const controllers_path = std.fmt.allocPrint(allocator, "/sys/fs/cgroup/{s}/cgroup.controllers", .{parent}) catch return;
    defer allocator.free(controllers_path);

    const subtree_path = std.fmt.allocPrint(allocator, "/sys/fs/cgroup/{s}/cgroup.subtree_control", .{parent}) catch return;
    defer allocator.free(subtree_path);

    const file = std.fs.openFileAbsolute(controllers_path, .{}) catch return;
    defer file.close();

    var buf: [512]u8 = undefined;
    const n = file.readAll(&buf) catch return;
    const controllers = std.mem.trim(u8, buf[0..n], " \n");

    // Write "+controller" for each available controller
    var iter = std.mem.tokenizeScalar(u8, controllers, ' ');
    while (iter.next()) |controller| {
        var write_buf: [64]u8 = undefined;
        const enable = std.fmt.bufPrint(&write_buf, "+{s}", .{controller}) catch continue;

        const out = std.fs.openFileAbsolute(subtree_path, .{ .mode = .write_only }) catch continue;
        defer out.close();
        out.writeAll(enable) catch {};
    }

    // Also enable in the root cgroup
    {
        const root_subtree = std.fs.openFileAbsolute("/sys/fs/cgroup/cgroup.subtree_control", .{ .mode = .write_only }) catch return;
        defer root_subtree.close();

        iter = std.mem.tokenizeScalar(u8, controllers, ' ');
        while (iter.next()) |controller| {
            var write_buf: [64]u8 = undefined;
            const enable = std.fmt.bufPrint(&write_buf, "+{s}", .{controller}) catch continue;
            root_subtree.writeAll(enable) catch {};
        }
    }
}

// --- Helpers ---

fn writeStr(cgroup_path: []const u8, filename: []const u8, value: []const u8) void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cgroup_path, filename }) catch return;
    const file = std.fs.openFileAbsolute(full_path, .{ .mode = .write_only }) catch |err| {
        scoped_log.debug("Cannot open {s}: {}", .{ full_path, err });
        return;
    };
    defer file.close();
    file.writeAll(value) catch |err| {
        scoped_log.debug("Cannot write to {s}: {}", .{ full_path, err });
    };
}

fn writeU64(cgroup_path: []const u8, filename: []const u8, value: u64) void {
    var buf: [32]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
    writeStr(cgroup_path, filename, str);
}

fn writeCpuMax(cgroup_path: []const u8, quota: u64, period: u64) void {
    var buf: [64]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d} {d}", .{ quota, period }) catch return;
    writeStr(cgroup_path, "cpu.max", str);
}

fn readU64(cgroup_path: []const u8, filename: []const u8) ?u64 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cgroup_path, filename }) catch return null;
    const file = std.fs.openFileAbsolute(full_path, .{}) catch return null;
    defer file.close();
    var buf: [64]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    const trimmed = std.mem.trim(u8, buf[0..n], " \n");
    return std.fmt.parseInt(u64, trimmed, 10) catch null;
}

// --- cgroup version detection and v1 support ---

pub const CgroupVersion = enum { v1, v2 };

pub fn detectVersion() CgroupVersion {
    std.fs.accessAbsolute("/sys/fs/cgroup/cgroup.controllers", .{}) catch return .v1;
    return .v2;
}

/// Unified cgroup handle supporting both v1 and v2
pub const CgroupHandle = union(enum) {
    v1: CgroupV1,
    v2: Cgroup,

    pub fn create(allocator: std.mem.Allocator, prefix: []const u8, id: []const u8) CgroupError!CgroupHandle {
        return switch (detectVersion()) {
            .v2 => .{ .v2 = try Cgroup.create(allocator, prefix, id) },
            .v1 => .{ .v1 = try CgroupV1.create(allocator, prefix, id) },
        };
    }

    pub fn setResources(self: *CgroupHandle, resources: *const Resources) void {
        switch (self.*) {
            .v2 => |*cg| cg.setResources(resources),
            .v1 => |*cg| cg.setResources(resources),
        }
    }

    pub fn addProcess(self: *CgroupHandle, pid: i32) CgroupError!void {
        return switch (self.*) {
            .v2 => |*cg| cg.addProcess(pid),
            .v1 => |*cg| cg.addProcess(pid),
        };
    }

    pub fn destroy(self: *CgroupHandle) void {
        switch (self.*) {
            .v2 => |*cg| cg.destroy(),
            .v1 => |*cg| cg.destroy(),
        }
    }

    pub fn kill(self: *CgroupHandle) void {
        switch (self.*) {
            .v2 => |*cg| cg.kill(),
            .v1 => |*cg| cg.killAll(),
        }
    }
};

/// cgroup v1: resources split across per-controller mount points
pub const CgroupV1 = struct {
    prefix: []const u8,
    id: []const u8,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, prefix: []const u8, id: []const u8) CgroupError!CgroupV1 {
        const self = CgroupV1{
            .prefix = allocator.dupe(u8, prefix) catch return error.OutOfMemory,
            .id = allocator.dupe(u8, id) catch return error.OutOfMemory,
            .allocator = allocator,
        };

        // Create directories under each controller
        const controllers = [_][]const u8{ "memory", "cpu", "cpuacct", "pids", "cpuset", "freezer" };
        for (controllers) |ctrl| {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/sys/fs/cgroup/{s}/{s}/{s}", .{ ctrl, prefix, id }) catch continue;
            var root = std.fs.openDirAbsolute("/sys/fs/cgroup", .{}) catch continue;
            defer root.close();
            const rel = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}", .{ ctrl, prefix, id }) catch continue;
            _ = path;
            root.makePath(rel) catch continue;
        }

        return self;
    }

    pub fn setResources(self: *const CgroupV1, resources: *const Resources) void {
        if (resources.memory_max > 0) {
            self.writeController("memory", "memory.limit_in_bytes", resources.memory_max);
        }
        if (resources.memory_swap_max > 0) {
            self.writeController("memory", "memory.memsw.limit_in_bytes", resources.memory_swap_max);
        }
        if (resources.cpu_quota > 0) {
            self.writeController("cpu", "cpu.cfs_quota_us", resources.cpu_quota);
            self.writeController("cpu", "cpu.cfs_period_us", resources.cpu_period);
        }
        if (resources.cpu_weight > 0 and resources.cpu_weight != 100) {
            // v1 uses shares, not weight. Approximate: shares = weight * 1024 / 100
            const shares = @as(u64, resources.cpu_weight) * 1024 / 100;
            self.writeController("cpu", "cpu.shares", shares);
        }
        if (resources.pids_max > 0) {
            self.writeController("pids", "pids.max", resources.pids_max);
        }
        if (resources.cpuset) |cpus| {
            self.writeControllerStr("cpuset", "cpuset.cpus", cpus);
            self.writeControllerStr("cpuset", "cpuset.mems", "0");
        }
    }

    pub fn addProcess(self: *const CgroupV1, pid: i32) CgroupError!void {
        var buf: [32]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch return error.WriteFailed;
        const controllers = [_][]const u8{ "memory", "cpu", "cpuacct", "pids", "cpuset", "freezer" };
        for (controllers) |ctrl| {
            self.writeControllerStr(ctrl, "tasks", pid_str);
        }
    }

    pub fn destroy(self: *CgroupV1) void {
        const controllers = [_][]const u8{ "memory", "cpu", "cpuacct", "pids", "cpuset", "freezer" };
        for (controllers) |ctrl| {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/sys/fs/cgroup/{s}/{s}/{s}", .{ ctrl, self.prefix, self.id }) catch continue;
            std.fs.deleteTreeAbsolute(path) catch {};
        }
        self.allocator.free(self.prefix);
        self.allocator.free(self.id);
    }

    pub fn killAll(self: *const CgroupV1) void {
        // Read PIDs from freezer cgroup and kill each
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/sys/fs/cgroup/freezer/{s}/{s}/cgroup.procs", .{ self.prefix, self.id }) catch return;
        const file = std.fs.openFileAbsolute(path, .{}) catch return;
        defer file.close();
        var buf: [4096]u8 = undefined;
        const n = file.readAll(&buf) catch return;
        var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \n");
            if (trimmed.len == 0) continue;
            const pid = std.fmt.parseInt(i32, trimmed, 10) catch continue;
            _ = std.os.linux.kill(pid, std.os.linux.SIG.KILL);
        }
    }

    fn writeController(self: *const CgroupV1, controller: []const u8, filename: []const u8, value: u64) void {
        var val_buf: [32]u8 = undefined;
        const str = std.fmt.bufPrint(&val_buf, "{d}", .{value}) catch return;
        self.writeControllerStr(controller, filename, str);
    }

    fn writeControllerStr(self: *const CgroupV1, controller: []const u8, filename: []const u8, value: []const u8) void {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/sys/fs/cgroup/{s}/{s}/{s}/{s}", .{ controller, self.prefix, self.id, filename }) catch return;
        const file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch return;
        defer file.close();
        file.writeAll(value) catch {};
    }
};

/// Cgroup driver mode
pub const CgroupDriver = enum {
    /// Direct filesystem access (default)
    cgroupfs,
    /// Delegate to systemd via systemd-run
    systemd,
};

/// Create a cgroup using systemd transient scope
pub fn createSystemdScope(allocator: std.mem.Allocator, id: []const u8, resources: *const Resources) !void {
    var args: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (args.items) |a| allocator.free(a);
        args.deinit(allocator);
    }

    try args.appendSlice(allocator, &.{
        try allocator.dupe(u8, "systemd-run"),
        try allocator.dupe(u8, "--scope"),
        try allocator.dupe(u8, "--slice=runz.slice"),
    });
    try args.append(allocator, try std.fmt.allocPrint(allocator, "--unit=runz-{s}.scope", .{id}));

    if (resources.memory_max > 0) {
        try args.append(allocator, try std.fmt.allocPrint(allocator, "-p MemoryMax={d}", .{resources.memory_max}));
    }
    if (resources.cpu_quota > 0) {
        try args.append(allocator, try std.fmt.allocPrint(allocator, "-p CPUQuota={d}%", .{resources.cpu_quota * 100 / resources.cpu_period}));
    }
    if (resources.pids_max > 0) {
        try args.append(allocator, try std.fmt.allocPrint(allocator, "-p TasksMax={d}", .{resources.pids_max}));
    }

    try args.append(allocator, try allocator.dupe(u8, "/bin/true"));

    var child = std.process.Child.init(args.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch return;
    _ = child.wait() catch return;
}

test "Resources defaults" {
    const r = Resources{};
    try std.testing.expectEqual(@as(u64, 0), r.memory_max);
    try std.testing.expectEqual(@as(u64, 100000), r.cpu_period);
    try std.testing.expectEqual(@as(u32, 100), r.cpu_weight);
    try std.testing.expectEqual(@as(u32, 0), r.pids_max);
}
