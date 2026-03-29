const std = @import("std");

pub const SystemError = error{
    CannotReadMemInfo,
    ParseError,
};

/// Memory information from /proc/meminfo
pub const MemInfo = struct {
    /// Total physical memory in bytes
    total: u64,
    /// Available memory in bytes (MemAvailable or Free + Buffers + Cached)
    available: u64,
    /// Free memory in bytes
    free: u64,
    /// Memory used by buffers
    buffers: u64,
    /// Memory used by cache
    cached: u64,
    /// Total swap in bytes
    swap_total: u64 = 0,
    /// Free swap in bytes
    swap_free: u64 = 0,

    /// Get percentage of memory available
    pub fn availablePercent(self: MemInfo) f64 {
        if (self.total == 0) return 0;
        return @as(f64, @floatFromInt(self.available)) / @as(f64, @floatFromInt(self.total)) * 100.0;
    }

    /// Read memory information from /proc/meminfo
    pub fn get() SystemError!MemInfo {
        const file = std.fs.openFileAbsolute("/proc/meminfo", .{}) catch {
            return error.CannotReadMemInfo;
        };
        defer file.close();

        var buf: [4096]u8 = undefined;
        const n = file.readAll(&buf) catch return error.CannotReadMemInfo;
        const content = buf[0..n];

        var info = MemInfo{
            .total = 0,
            .available = 0,
            .free = 0,
            .buffers = 0,
            .cached = 0,
        };

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var parts = std.mem.tokenizeAny(u8, line, ": \t");
            const key = parts.next() orelse continue;
            const val_str = parts.next() orelse continue;
            const val = std.fmt.parseInt(u64, val_str, 10) catch continue;
            const bytes = val * 1024;

            if (std.mem.eql(u8, key, "MemTotal")) {
                info.total = bytes;
            } else if (std.mem.eql(u8, key, "MemAvailable")) {
                info.available = bytes;
            } else if (std.mem.eql(u8, key, "MemFree")) {
                info.free = bytes;
            } else if (std.mem.eql(u8, key, "Buffers")) {
                info.buffers = bytes;
            } else if (std.mem.eql(u8, key, "Cached")) {
                info.cached = bytes;
            } else if (std.mem.eql(u8, key, "SwapTotal")) {
                info.swap_total = bytes;
            } else if (std.mem.eql(u8, key, "SwapFree")) {
                info.swap_free = bytes;
            }
        }

        // If MemAvailable isn't present (older kernels), estimate it
        if (info.available == 0) {
            info.available = info.free + info.buffers + info.cached;
        }

        return info;
    }
};

/// Format bytes as human-readable string
pub fn formatBytes(bytes: u64, buf: []u8) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB", "PB" };
    var size: f64 = @floatFromInt(bytes);
    var unit_idx: usize = 0;

    while (size >= 1024 and unit_idx < units.len - 1) {
        size /= 1024;
        unit_idx += 1;
    }

    return std.fmt.bufPrint(buf, "{d:.2} {s}", .{ size, units[unit_idx] }) catch "?";
}
