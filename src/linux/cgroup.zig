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

test "Resources defaults" {
    const r = Resources{};
    try std.testing.expectEqual(@as(u64, 0), r.memory_max);
    try std.testing.expectEqual(@as(u64, 100000), r.cpu_period);
    try std.testing.expectEqual(@as(u32, 100), r.cpu_weight);
    try std.testing.expectEqual(@as(u32, 0), r.pids_max);
}
