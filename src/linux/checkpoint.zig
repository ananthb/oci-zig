const std = @import("std");
const log = @import("../log.zig");

const scoped_log = log.scoped("checkpoint");

pub const CheckpointError = error{
    CriuNotAvailable,
    CheckpointFailed,
    RestoreFailed,
    SpawnFailed,
    OutOfMemory,
};

/// Check if the CRIU binary is available on the system.
pub fn isCriuAvailable() bool {
    std.fs.accessAbsolute("/usr/sbin/criu", .{}) catch {
        std.fs.accessAbsolute("/usr/local/sbin/criu", .{}) catch {
            std.fs.accessAbsolute("/usr/bin/criu", .{}) catch {
                scoped_log.debug("CRIU binary not found", .{});
                return false;
            };
        };
    };
    return true;
}

/// Checkpoint a running container by shelling out to `criu dump`.
/// container_pid: PID of the container's init process.
/// image_dir: directory to store checkpoint images.
pub fn checkpoint(
    allocator: std.mem.Allocator,
    container_pid: i32,
    image_dir: []const u8,
) CheckpointError!void {
    if (!isCriuAvailable()) return error.CriuNotAvailable;

    var pid_buf: [16]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{container_pid}) catch
        return error.CheckpointFailed;

    const args = [_][]const u8{
        "criu",
        "dump",
        "-t",
        pid_str,
        "-D",
        image_dir,
        "--shell-job",
        "--tcp-established",
    };

    var child = std.process.Child.init(&args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch {
        scoped_log.warn("Failed to spawn criu dump", .{});
        return error.SpawnFailed;
    };

    const result = child.wait() catch {
        scoped_log.warn("Failed to wait for criu dump", .{});
        return error.CheckpointFailed;
    };

    if (result.Exited != 0) {
        scoped_log.warn("criu dump exited with code {d}", .{result.Exited});
        return error.CheckpointFailed;
    }

    scoped_log.debug("Checkpoint completed to {s}", .{image_dir});
}

/// Restore a container from a checkpoint by shelling out to `criu restore`.
/// image_dir: directory containing checkpoint images.
pub fn restore(
    allocator: std.mem.Allocator,
    image_dir: []const u8,
) CheckpointError!void {
    if (!isCriuAvailable()) return error.CriuNotAvailable;

    const args = [_][]const u8{
        "criu",
        "restore",
        "-D",
        image_dir,
        "--shell-job",
        "--tcp-established",
        "-d",
    };

    var child = std.process.Child.init(&args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch {
        scoped_log.warn("Failed to spawn criu restore", .{});
        return error.SpawnFailed;
    };

    const result = child.wait() catch {
        scoped_log.warn("Failed to wait for criu restore", .{});
        return error.RestoreFailed;
    };

    if (result.Exited != 0) {
        scoped_log.warn("criu restore exited with code {d}", .{result.Exited});
        return error.RestoreFailed;
    }

    scoped_log.debug("Restore completed from {s}", .{image_dir});
}

/// Get CRIU version string, or null if CRIU is not available.
pub fn getCriuVersion(allocator: std.mem.Allocator) ?[]const u8 {
    const args = [_][]const u8{ "criu", "--version" };
    var child = std.process.Child.init(&args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch return null;

    var stdout_buf: [256]u8 = undefined;
    const stdout = child.stdout orelse return null;
    const n = stdout.readAll(&stdout_buf) catch return null;
    _ = child.wait() catch return null;

    const output = std.mem.trim(u8, stdout_buf[0..n], " \n\r");
    return allocator.dupe(u8, output) catch null;
}

test "isCriuAvailable returns bool" {
    // Just verify it doesn't crash - actual result depends on system
    _ = isCriuAvailable();
}

test "CheckpointError values" {
    const err: CheckpointError = error.CriuNotAvailable;
    try std.testing.expect(err == error.CriuNotAvailable);
}
