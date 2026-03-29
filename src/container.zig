const std = @import("std");
const linux = std.os.linux;
const log = @import("log.zig");
const runtime_spec = @import("runtime_spec.zig");
const cgroup = @import("linux/cgroup.zig");
const run = @import("run.zig");

const scoped_log = log.scoped("container");

/// Container states per OCI runtime spec
pub const State = enum {
    creating,
    created,
    running,
    stopped,

    pub fn string(self: State) []const u8 {
        return @tagName(self);
    }
};

/// Container metadata
pub const ContainerInfo = struct {
    id: []const u8,
    pid: ?i32 = null,
    state: State = .creating,
    bundle: []const u8,
    created: i64 = 0,
    allocator: std.mem.Allocator,
    cg: ?cgroup.Cgroup = null,

    pub fn deinit(self: *ContainerInfo) void {
        if (self.cg) |*cg| cg.destroy();
        self.allocator.free(self.id);
        self.allocator.free(self.bundle);
    }

    /// Serialize state to JSON for state.json
    pub fn toJson(self: *const ContainerInfo, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator,
            \\{{"ociVersion":"1.0.2","id":"{s}","status":"{s}","pid":{d},"bundle":"{s}"}}
        , .{
            self.id,
            self.state.string(),
            self.pid orelse 0,
            self.bundle,
        });
    }
};

/// Container manager — tracks containers by ID in a state directory
pub const Manager = struct {
    state_dir: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, state_dir: []const u8) Manager {
        // Ensure state directory exists
        std.fs.makeDirAbsolute(state_dir) catch {};
        return .{ .state_dir = state_dir, .allocator = allocator };
    }

    /// Create a container (OCI lifecycle: creating → created)
    pub fn create(self: *Manager, id: []const u8, bundle: []const u8, resources: ?*const cgroup.Resources) !ContainerInfo {
        scoped_log.info("Creating container {s} from {s}", .{ id, bundle });

        var info = ContainerInfo{
            .id = try self.allocator.dupe(u8, id),
            .bundle = try self.allocator.dupe(u8, bundle),
            .created = std.time.timestamp(),
            .allocator = self.allocator,
        };
        errdefer info.deinit();

        // Create cgroup if resources are specified
        if (resources) |res| {
            info.cg = cgroup.Cgroup.create(self.allocator, "runz", id) catch null;
            if (info.cg) |*cg| {
                cg.setResources(res);
            }
        }

        info.state = .created;
        try self.saveState(&info);

        return info;
    }

    /// Start a container (OCI lifecycle: created → running)
    pub fn start(self: *Manager, info: *ContainerInfo, argv: []const []const u8, options: run.ContainerOptions) !void {
        scoped_log.info("Starting container {s}", .{info.id});

        // Run the container (this blocks until it exits)
        // For a proper runtime, this would fork and return the PID
        info.state = .running;
        try self.saveState(info);

        const exit_code = try run.runContainer(
            self.allocator,
            info.bundle,
            argv,
            options,
        );

        info.state = .stopped;
        info.pid = null;
        self.saveState(info) catch {};

        if (exit_code != 0) {
            scoped_log.info("Container {s} exited with code {d}", .{ info.id, exit_code });
        }
    }

    /// Kill a container's processes
    pub fn kill(self: *Manager, info: *ContainerInfo, signal: i32) void {
        _ = self;
        if (info.cg) |*cg| {
            if (signal == linux.SIG.KILL) {
                cg.kill();
            }
        }
        if (info.pid) |pid| {
            _ = linux.kill(pid, signal);
        }
    }

    /// Delete a stopped container
    pub fn delete(self: *Manager, info: *ContainerInfo) void {
        scoped_log.info("Deleting container {s}", .{info.id});
        self.deleteState(info.id);
        info.deinit();
    }

    /// List container IDs in the state directory
    pub fn list(self: *Manager, allocator: std.mem.Allocator) ![][]const u8 {
        var dir = std.fs.openDirAbsolute(self.state_dir, .{ .iterate = true }) catch return &.{};
        defer dir.close();

        var ids: std.ArrayListUnmanaged([]const u8) = .{};
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
                const id = entry.name[0 .. entry.name.len - 5]; // strip .json
                try ids.append(allocator, try allocator.dupe(u8, id));
            }
        }
        return try ids.toOwnedSlice(allocator);
    }

    // --- State persistence ---

    fn saveState(self: *Manager, info: *const ContainerInfo) !void {
        const json = try info.toJson(self.allocator);
        defer self.allocator.free(json);

        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.json", .{ self.state_dir, info.id });
        defer self.allocator.free(path);

        const dir_path = std.fs.path.dirname(path) orelse "/";
        var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return error.WriteFailed;
        defer dir.close();
        var file = dir.createFile(std.fs.path.basename(path), .{}) catch return error.WriteFailed;
        defer file.close();
        file.writeAll(json) catch return error.WriteFailed;
    }

    fn deleteState(self: *Manager, id: []const u8) void {
        const path = std.fmt.allocPrint(self.allocator, "{s}/{s}.json", .{ self.state_dir, id }) catch return;
        defer self.allocator.free(path);
        std.fs.deleteFileAbsolute(path) catch {};
    }
};

test "container state enum" {
    try std.testing.expectEqualStrings("creating", State.creating.string());
    try std.testing.expectEqualStrings("created", State.created.string());
    try std.testing.expectEqualStrings("running", State.running.string());
    try std.testing.expectEqualStrings("stopped", State.stopped.string());
}

test "ContainerInfo toJson" {
    const allocator = std.testing.allocator;
    const info = ContainerInfo{
        .id = "test-container-123",
        .pid = 42,
        .state = .running,
        .bundle = "/tmp/test-bundle",
        .created = 1700000000,
        .allocator = allocator,
    };
    const json = try info.toJson(allocator);
    defer allocator.free(json);

    // Verify JSON contains expected fields
    try std.testing.expect(std.mem.indexOf(u8, json, "test-container-123") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "running") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "42") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/tmp/test-bundle") != null);
}

test "ContainerInfo defaults" {
    const info = ContainerInfo{
        .id = "x",
        .bundle = "/b",
        .allocator = std.testing.allocator,
    };
    try std.testing.expect(info.pid == null);
    try std.testing.expectEqual(State.creating, info.state);
    try std.testing.expect(info.cg == null);
}
