const std = @import("std");

/// Process information from /proc
pub const ProcessInfo = struct {
    pid: i32,
    ppid: i32,
    comm: []const u8,
    cmdline: []const u8,
    state: u8,
    uid: u32,
    gid: u32,

    pub fn deinit(self: *ProcessInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.comm);
        allocator.free(self.cmdline);
    }

    /// Check if this is a kernel thread
    pub fn isKernelThread(self: *const ProcessInfo) bool {
        if (self.ppid == 0 or self.ppid == 2) return true;
        if (self.comm.len > 0 and self.comm[0] == '[') return true;
        return false;
    }

    /// Check if this is the current process
    pub fn isSelf(self: *const ProcessInfo) bool {
        return self.pid == std.os.linux.getpid();
    }

    /// Check if this is init (PID 1)
    pub fn isInit(self: *const ProcessInfo) bool {
        return self.pid == 1;
    }
};

/// Scan all processes in the system
pub fn scanProcesses(allocator: std.mem.Allocator) ![]ProcessInfo {
    var processes: std.ArrayListUnmanaged(ProcessInfo) = .{};
    errdefer {
        for (processes.items) |*p| p.deinit(allocator);
        processes.deinit(allocator);
    }

    var proc_dir = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch {
        return error.ProcNotAvailable;
    };
    defer proc_dir.close();

    var iter = proc_dir.iterate();
    while (iter.next() catch null) |entry| {
        // Only process numeric directories (PIDs)
        const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;

        if (getProcessInfo(allocator, pid)) |info| {
            try processes.append(allocator, info);
        } else |_| {
            // Process may have exited, skip
        }
    }

    return processes.toOwnedSlice(allocator);
}

/// Get information about a specific process
pub fn getProcessInfo(allocator: std.mem.Allocator, pid: i32) !ProcessInfo {
    var path_buf: [64]u8 = undefined;

    // Read /proc/PID/stat
    const stat_path = try std.fmt.bufPrint(&path_buf, "/proc/{}/stat", .{pid});
    const stat_content = try readProcFile(allocator, stat_path);
    defer allocator.free(stat_content);

    // Parse stat file
    const comm_start = std.mem.indexOf(u8, stat_content, "(") orelse return error.ParseError;
    const comm_end = std.mem.lastIndexOf(u8, stat_content, ")") orelse return error.ParseError;

    const comm = try allocator.dupe(u8, stat_content[comm_start + 1 .. comm_end]);
    errdefer allocator.free(comm);

    // Parse remaining fields after comm
    const after_comm = stat_content[comm_end + 2 ..];
    var fields = std.mem.tokenizeScalar(u8, after_comm, ' ');

    const state_str = fields.next() orelse return error.ParseError;
    const state = if (state_str.len > 0) state_str[0] else '?';

    const ppid_str = fields.next() orelse return error.ParseError;
    const ppid = try std.fmt.parseInt(i32, ppid_str, 10);

    // Read cmdline
    const cmdline_path = try std.fmt.bufPrint(&path_buf, "/proc/{}/cmdline", .{pid});
    const cmdline = readProcFile(allocator, cmdline_path) catch try allocator.dupe(u8, "");
    errdefer allocator.free(cmdline);

    // Replace null bytes with spaces in cmdline
    for (cmdline) |*c| {
        if (c.* == 0) c.* = ' ';
    }

    // Read status for uid/gid
    const status_path = try std.fmt.bufPrint(&path_buf, "/proc/{}/status", .{pid});
    var uid: u32 = 0;
    var gid: u32 = 0;

    if (readProcFile(allocator, status_path)) |status_content| {
        defer allocator.free(status_content);

        var lines = std.mem.splitScalar(u8, status_content, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "Uid:")) {
                var parts = std.mem.tokenizeAny(u8, line[4..], "\t ");
                if (parts.next()) |uid_str| {
                    uid = std.fmt.parseInt(u32, uid_str, 10) catch 0;
                }
            } else if (std.mem.startsWith(u8, line, "Gid:")) {
                var parts = std.mem.tokenizeAny(u8, line[4..], "\t ");
                if (parts.next()) |gid_str| {
                    gid = std.fmt.parseInt(u32, gid_str, 10) catch 0;
                }
            }
        }
    } else |_| {}

    return ProcessInfo{
        .pid = pid,
        .ppid = ppid,
        .comm = comm,
        .cmdline = cmdline,
        .state = state,
        .uid = uid,
        .gid = gid,
    };
}

/// Read a file from /proc
fn readProcFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, 1024 * 1024);
}

/// Get process count
pub fn getProcessCount() u32 {
    var count: u32 = 0;
    var proc_dir = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch return 0;
    defer proc_dir.close();

    var iter = proc_dir.iterate();
    while (iter.next() catch null) |entry| {
        _ = std.fmt.parseInt(i32, entry.name, 10) catch continue;
        count += 1;
    }
    return count;
}

/// Check if a process is still running
pub fn isProcessRunning(pid: i32) bool {
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{}", .{pid}) catch return false;
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}
