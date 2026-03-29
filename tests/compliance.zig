const std = @import("std");
const helpers = @import("helpers.zig");

// ============================================================================
// OCI Runtime Compliance Tests
//
// These verify runz conforms to the OCI Runtime Spec by exercising the CLI
// commands that container engines (podman, containerd) depend on.
//
// Requires root for namespace operations. Tests skip if not root.
// Requires the runz binary to be built: zig build
// ============================================================================

const runz_bin = "zig-out/bin/runz";

fn run(allocator: std.mem.Allocator, argv: []const []const u8) !struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
} {
    var child = std.process.Child.init(argv, allocator);
    // Don't pipe stdout/stderr — the forked container child inherits them
    // and keeps them open, blocking readAll. Instead, just wait for exit.
    child.spawn() catch return error.SpawnFailed;

    const result = child.wait() catch return error.WaitFailed;
    const exit_code: u8 = switch (result) {
        .Exited => |code| code,
        .Signal => 128,
        .Stopped => 128,
        else => 255,
    };
    return .{
        .stdout = try allocator.dupe(u8, ""),
        .stderr = try allocator.dupe(u8, ""),
        .exit_code = exit_code,
    };
}

/// Run a command and capture output (for commands that don't fork children)
fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8) !struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
} {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch return error.SpawnFailed;

    var stdout_buf: [65536]u8 = undefined;
    var stderr_buf: [65536]u8 = undefined;
    const stdout_n = child.stdout.?.readAll(&stdout_buf) catch 0;
    const stderr_n = child.stderr.?.readAll(&stderr_buf) catch 0;

    const result = child.wait() catch return error.WaitFailed;
    const exit_code: u8 = switch (result) {
        .Exited => |code| code,
        .Signal => 128,
        .Stopped => 128,
        else => 255,
    };
    return .{
        .stdout = try allocator.dupe(u8, stdout_buf[0..stdout_n]),
        .stderr = try allocator.dupe(u8, stderr_buf[0..stderr_n]),
        .exit_code = exit_code,
    };
}

fn requireRoot() bool {
    return std.os.linux.getuid() == 0;
}

// --- spec ---

test "compliance: spec produces valid JSON with ociVersion" {
    const allocator = std.testing.allocator;
    const result = try runCapture(allocator, &.{ runz_bin, "spec" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();

    // Required OCI fields
    const oci_version = parsed.value.object.get("ociVersion") orelse return error.MissingField;
    try std.testing.expectEqualStrings("1.0.2", oci_version.string);
    try std.testing.expect(parsed.value.object.get("process") != null);
    try std.testing.expect(parsed.value.object.get("root") != null);
    try std.testing.expect(parsed.value.object.get("linux") != null);
    try std.testing.expect(parsed.value.object.get("mounts") != null);
}

test "compliance: spec has namespaces" {
    const allocator = std.testing.allocator;
    const result = try runCapture(allocator, &.{ runz_bin, "spec" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();

    const lnx = parsed.value.object.get("linux") orelse return error.MissingField;
    const ns = lnx.object.get("namespaces") orelse return error.MissingField;
    try std.testing.expect(ns.array.items.len >= 3);
}

test "compliance: spec has maskedPaths and readonlyPaths" {
    const allocator = std.testing.allocator;
    const result = try runCapture(allocator, &.{ runz_bin, "spec" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();

    const lnx = parsed.value.object.get("linux") orelse return error.MissingField;
    try std.testing.expect(lnx.object.get("maskedPaths") != null);
    try std.testing.expect(lnx.object.get("readonlyPaths") != null);
}

// --- create / state / start / delete lifecycle ---

test "compliance: create produces state with required fields" {
    if (!requireRoot()) return;

    const allocator = std.testing.allocator;
    const ts: u64 = @intCast(std.time.timestamp());
    const state_dir = try std.fmt.allocPrint(allocator, "/tmp/runz-comply-{x}", .{ts});
    defer allocator.free(state_dir);
    std.fs.makeDirAbsolute(state_dir) catch return;
    defer std.fs.deleteTreeAbsolute(state_dir) catch {};

    const config = try helpers.minimalConfig(allocator, &.{"/bin/true"});
    defer allocator.free(config);
    const bundle = try helpers.createTestBundle(allocator, config);
    defer {
        helpers.cleanupBundle(bundle);
        allocator.free(bundle);
    }

    // create
    const create_result = try run(allocator, &.{ runz_bin, "--root", state_dir, "create", "oci-test", "-b", bundle });
    defer allocator.free(create_result.stdout);
    defer allocator.free(create_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), create_result.exit_code);

    // state must have ociVersion, id, status=created, pid, bundle
    const state_result = try runCapture(allocator, &.{ runz_bin, "--root", state_dir, "state", "oci-test" });
    defer allocator.free(state_result.stdout);
    defer allocator.free(state_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), state_result.exit_code);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, state_result.stdout, .{});
    defer parsed.deinit();

    // Required fields per OCI runtime spec
    const oci_ver = parsed.value.object.get("ociVersion") orelse return error.MissingField;
    try std.testing.expectEqualStrings("1.0.2", oci_ver.string);

    const id = parsed.value.object.get("id") orelse return error.MissingField;
    try std.testing.expectEqualStrings("oci-test", id.string);

    const status = parsed.value.object.get("status") orelse return error.MissingField;
    try std.testing.expectEqualStrings("created", status.string);

    try std.testing.expect(parsed.value.object.get("pid") != null);
    try std.testing.expect(parsed.value.object.get("bundle") != null);

    // pid must be > 0
    const pid = parsed.value.object.get("pid").?;
    try std.testing.expect(pid.integer > 0);

    // start
    const start_result = try run(allocator, &.{ runz_bin, "--root", state_dir, "start", "oci-test" });
    defer allocator.free(start_result.stdout);
    defer allocator.free(start_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), start_result.exit_code);

    std.Thread.sleep(500 * std.time.ns_per_ms);

    // kill + delete
    const kill_result = try run(allocator, &.{ runz_bin, "--root", state_dir, "kill", "oci-test", "SIGKILL" });
    defer allocator.free(kill_result.stdout);
    defer allocator.free(kill_result.stderr);

    std.Thread.sleep(500 * std.time.ns_per_ms);

    const del_result = try run(allocator, &.{ runz_bin, "--root", state_dir, "delete", "oci-test" });
    defer allocator.free(del_result.stdout);
    defer allocator.free(del_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), del_result.exit_code);

    // state after delete must fail
    const state2 = try runCapture(allocator, &.{ runz_bin, "--root", state_dir, "state", "oci-test" });
    defer allocator.free(state2.stdout);
    defer allocator.free(state2.stderr);
    try std.testing.expect(state2.exit_code != 0);
}

// --- run ---

test "compliance: run executes process and returns output" {
    if (!requireRoot()) return;

    const allocator = std.testing.allocator;
    const ts: u64 = @intCast(std.time.timestamp());
    const state_dir = try std.fmt.allocPrint(allocator, "/tmp/runz-comply-run-{x}", .{ts});
    defer allocator.free(state_dir);
    std.fs.makeDirAbsolute(state_dir) catch return;
    defer std.fs.deleteTreeAbsolute(state_dir) catch {};

    const config = try helpers.minimalConfig(allocator, &.{ "/bin/echo", "oci-compliance-ok" });
    defer allocator.free(config);
    const bundle = try helpers.createTestBundle(allocator, config);
    defer {
        helpers.cleanupBundle(bundle);
        allocator.free(bundle);
    }

    const result = try runCapture(allocator, &.{ runz_bin, "--root", state_dir, "run", "run-test", "-b", bundle });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Output should contain our message (might be in stdout or stderr due to logging)
    const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ result.stdout, result.stderr });
    defer allocator.free(combined);
    try std.testing.expect(std.mem.indexOf(u8, combined, "oci-compliance-ok") != null);
}

test "compliance: run with mounts has /proc" {
    if (!requireRoot()) return;

    const allocator = std.testing.allocator;
    const ts: u64 = @intCast(std.time.timestamp());
    const state_dir = try std.fmt.allocPrint(allocator, "/tmp/runz-comply-mnt-{x}", .{ts});
    defer allocator.free(state_dir);
    std.fs.makeDirAbsolute(state_dir) catch return;
    defer std.fs.deleteTreeAbsolute(state_dir) catch {};

    // Config with /proc mount
    var args_json: std.ArrayListUnmanaged(u8) = .{};
    defer args_json.deinit(allocator);
    try args_json.appendSlice(allocator,
        \\{"ociVersion":"1.0.2","process":{"args":["/bin/ls","/proc"],"cwd":"/","env":["PATH=/bin"]},
    );
    try args_json.appendSlice(allocator,
        \\"root":{"path":"rootfs"},"mounts":[{"destination":"/proc","type":"proc","source":"proc"}],
    );
    try args_json.appendSlice(allocator,
        \\"linux":{"namespaces":[{"type":"pid"},{"type":"mount"}]}}
    );

    const bundle = try helpers.createTestBundle(allocator, args_json.items);
    defer {
        helpers.cleanupBundle(bundle);
        allocator.free(bundle);
    }

    const result = try runCapture(allocator, &.{ runz_bin, "--root", state_dir, "run", "mnt-test", "-b", bundle });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // /proc should be populated (should see "1" for PID 1)
    const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ result.stdout, result.stderr });
    defer allocator.free(combined);
    try std.testing.expect(std.mem.indexOf(u8, combined, "1") != null);
}

// --- error handling ---

test "compliance: state of nonexistent container returns non-zero" {
    const allocator = std.testing.allocator;
    const result = try runCapture(allocator, &.{ runz_bin, "state", "nonexistent-oci-test" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expect(result.exit_code != 0);
}

test "compliance: create without bundle fails" {
    const allocator = std.testing.allocator;
    const result = try run(allocator, &.{ runz_bin, "create", "no-bundle-test" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expect(result.exit_code != 0);
}

test "compliance: delete of nonexistent container succeeds" {
    const allocator = std.testing.allocator;
    const ts: u64 = @intCast(std.time.timestamp());
    const state_dir = try std.fmt.allocPrint(allocator, "/tmp/runz-comply-del-{x}", .{ts});
    defer allocator.free(state_dir);
    std.fs.makeDirAbsolute(state_dir) catch return;
    defer std.fs.deleteTreeAbsolute(state_dir) catch {};

    // Delete should not error on nonexistent container (idempotent)
    const result = try run(allocator, &.{ runz_bin, "--root", state_dir, "delete", "ghost" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// --- pid-file ---

test "compliance: create --pid-file writes PID" {
    if (!requireRoot()) return;

    const allocator = std.testing.allocator;
    const ts: u64 = @intCast(std.time.timestamp());
    const state_dir = try std.fmt.allocPrint(allocator, "/tmp/runz-comply-pid-{x}", .{ts});
    defer allocator.free(state_dir);
    std.fs.makeDirAbsolute(state_dir) catch return;
    defer std.fs.deleteTreeAbsolute(state_dir) catch {};

    const pid_file = try std.fmt.allocPrint(allocator, "{s}/test.pid", .{state_dir});
    defer allocator.free(pid_file);

    const config = try helpers.minimalConfig(allocator, &.{"/bin/true"});
    defer allocator.free(config);
    const bundle = try helpers.createTestBundle(allocator, config);
    defer {
        helpers.cleanupBundle(bundle);
        allocator.free(bundle);
    }

    const result = try run(allocator, &.{
        runz_bin, "--root", state_dir, "create", "pidfile-test", "-b", bundle, "--pid-file", pid_file,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // PID file should exist and contain a number
    const file = std.fs.openFileAbsolute(pid_file, .{}) catch return error.TestUnexpectedResult;
    defer file.close();
    var buf: [32]u8 = undefined;
    const n = file.readAll(&buf) catch return error.TestUnexpectedResult;
    const pid = std.fmt.parseInt(i32, std.mem.trim(u8, buf[0..n], " \n"), 10) catch return error.TestUnexpectedResult;
    try std.testing.expect(pid > 0);

    // Cleanup
    const kill_r = try run(allocator, &.{ runz_bin, "--root", state_dir, "kill", "pidfile-test", "SIGKILL" });
    allocator.free(kill_r.stdout);
    allocator.free(kill_r.stderr);
    std.Thread.sleep(500 * std.time.ns_per_ms);
    const del_r = try run(allocator, &.{ runz_bin, "--root", state_dir, "delete", "pidfile-test" });
    allocator.free(del_r.stdout);
    allocator.free(del_r.stderr);
}
