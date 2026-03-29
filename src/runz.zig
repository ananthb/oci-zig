const std = @import("std");
const log = @import("log.zig");
const image = @import("image.zig");
const registry = @import("registry.zig");
const layer = @import("layer.zig");
const run = @import("run.zig");
const container_mod = @import("container.zig");
const cgroup = @import("linux/cgroup.zig");
const capabilities = @import("linux/capabilities.zig");
const paths = @import("linux/paths.zig");

const scoped_log = log.scoped("runz");

/// Options for runz (daemonless container execution)
pub const RunzOptions = struct {
    /// Container name/ID (auto-generated if null)
    name: ?[]const u8 = null,
    /// Environment variables
    env: ?[]const []const u8 = null,
    /// Working directory inside the container
    workdir: ?[]const u8 = null,
    /// Network mode
    network: run.NetworkMode = .veth,
    /// Run rootless (user namespace)
    rootless: bool = false,
    /// Resource limits
    resources: ?cgroup.Resources = null,
    /// Remove container on exit
    rm: bool = true,
    /// Pull image even if cached
    pull: bool = false,
    /// State directory for container metadata
    state_dir: []const u8 = "/run/runz",
    /// Cache directory for pulled images
    cache_dir: []const u8 = "/var/cache/runz",
};

/// Run a container image directly (like `podman run`).
/// Pulls the image, extracts layers, runs the entrypoint, cleans up.
/// Daemonless: the calling process blocks until the container exits.
pub fn runImage(
    allocator: std.mem.Allocator,
    image_ref: []const u8,
    command: ?[]const []const u8,
    options: RunzOptions,
) !u8 {
    scoped_log.info("runz: {s}", .{image_ref});

    // Generate container ID
    var id_buf: [16]u8 = undefined;
    const id = if (options.name) |n| n else blk: {
        // Use timestamp-based ID
        const ts: u64 = @intCast(std.time.timestamp());
        const hex = std.fmt.bytesToHex(std.mem.asBytes(&ts)[0..8], .lower);
        @memcpy(&id_buf, &hex);
        break :blk id_buf[0..16];
    };

    // Create working directory
    const work_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ options.state_dir, id });
    defer allocator.free(work_dir);
    const rootfs_dir = try std.fmt.allocPrint(allocator, "{s}/rootfs", .{work_dir});
    defer allocator.free(rootfs_dir);

    {
        var root = std.fs.openDirAbsolute("/", .{}) catch return error.SetupFailed;
        defer root.close();
        root.makePath(work_dir[1..]) catch return error.SetupFailed;
        root.makePath(rootfs_dir[1..]) catch return error.SetupFailed;
    }
    defer if (options.rm) {
        std.fs.deleteTreeAbsolute(work_dir) catch {};
    };

    // Pull image
    const pull_dir = try std.fmt.allocPrint(allocator, "{s}/pull", .{work_dir});
    defer allocator.free(pull_dir);
    std.fs.makeDirAbsolute(pull_dir) catch {};

    if (image.isLocalImage(image_ref)) {
        scoped_log.info("Using local image: {s}", .{image_ref});
    } else {
        var ref = image.ImageReference.parse(image_ref, allocator) catch return error.InvalidImage;
        defer ref.deinit(allocator);

        scoped_log.info("Pulling {s}/{s}:{s}", .{ ref.registry, ref.repository, ref.tag });
        registry.pullImage(allocator, &ref, pull_dir) catch return error.PullFailed;
    }

    // Extract layers to rootfs
    const index_path = try std.fmt.allocPrint(allocator, "{s}/index.json", .{pull_dir});
    defer allocator.free(index_path);

    if (std.fs.accessAbsolute(index_path, .{})) |_| {
        try extractOciLayout(allocator, pull_dir, rootfs_dir);
    } else |_| {
        // Local directory — copy or use directly
        if (image.isLocalImage(image_ref)) {
            // For tarballs, extract directly
            const compression: layer.Compression = if (std.mem.endsWith(u8, image_ref, ".tar.gz") or std.mem.endsWith(u8, image_ref, ".tgz"))
                .gzip
            else if (std.mem.endsWith(u8, image_ref, ".zst"))
                .zstd
            else
                .none;
            layer.extractLayer(image_ref, compression, .{ .target = rootfs_dir }, allocator) catch return error.ExtractionFailed;
        }
    }

    // Determine entrypoint from image config or command override
    var argv: std.ArrayListUnmanaged([]const u8) = .{};
    defer argv.deinit(allocator);

    if (command) |cmd| {
        for (cmd) |arg| try argv.append(allocator, arg);
    } else {
        // Try to read entrypoint from image config
        const config = readImageConfig(allocator, pull_dir) catch null;
        if (config) |cfg| {
            if (cfg.entrypoint) |ep| {
                for (ep) |arg| try argv.append(allocator, arg);
            }
            if (cfg.cmd) |cmd_args| {
                for (cmd_args) |arg| try argv.append(allocator, arg);
            }
        }
        if (argv.items.len == 0) {
            try argv.append(allocator, "/bin/sh");
        }
    }

    scoped_log.info("Entrypoint: {s}", .{argv.items[0]});

    // Apply masked/readonly paths after extraction
    paths.applyDefaults(rootfs_dir, allocator);

    // Run the container
    var container_opts = run.ContainerOptions{
        .env = options.env,
        .network = options.network,
        .rootless = options.rootless,
    };

    if (options.resources) |*res| {
        container_opts.resources = res;
    }

    return try run.runContainer(allocator, rootfs_dir, argv.items, container_opts);
}

/// Image config subset for entrypoint/cmd resolution
const ImageConfig = struct {
    entrypoint: ?[]const []const u8,
    cmd: ?[]const []const u8,
};

fn readImageConfig(allocator: std.mem.Allocator, layout_path: []const u8) !ImageConfig {
    // Read index.json → manifest → config
    const index_path = try std.fmt.allocPrint(allocator, "{s}/index.json", .{layout_path});
    defer allocator.free(index_path);

    const index_file = try std.fs.openFileAbsolute(index_path, .{});
    defer index_file.close();
    var index_buf: [16384]u8 = undefined;
    const index_n = try index_file.readAll(&index_buf);
    const index_parsed = try std.json.parseFromSlice(std.json.Value, allocator, index_buf[0..index_n], .{});
    defer index_parsed.deinit();

    const manifests = index_parsed.value.object.get("manifests") orelse return error.InvalidImage;
    if (manifests.array.items.len == 0) return error.InvalidImage;
    const digest = manifests.array.items[0].object.get("digest") orelse return error.InvalidImage;

    // Read manifest
    const hash = digest.string[7..]; // strip "sha256:"
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/blobs/sha256/{s}", .{ layout_path, hash });
    defer allocator.free(manifest_path);
    const manifest_file = try std.fs.openFileAbsolute(manifest_path, .{});
    defer manifest_file.close();
    var manifest_buf: [65536]u8 = undefined;
    const mn = try manifest_file.readAll(&manifest_buf);
    const manifest_parsed = try std.json.parseFromSlice(std.json.Value, allocator, manifest_buf[0..mn], .{});
    defer manifest_parsed.deinit();

    const config_desc = manifest_parsed.value.object.get("config") orelse return error.InvalidImage;
    const config_digest = config_desc.object.get("digest") orelse return error.InvalidImage;
    const config_hash = config_digest.string[7..];

    // Read config
    const config_path = try std.fmt.allocPrint(allocator, "{s}/blobs/sha256/{s}", .{ layout_path, config_hash });
    defer allocator.free(config_path);
    const config_file = try std.fs.openFileAbsolute(config_path, .{});
    defer config_file.close();
    var config_buf: [65536]u8 = undefined;
    const cn = try config_file.readAll(&config_buf);
    const config_parsed = try std.json.parseFromSlice(std.json.Value, allocator, config_buf[0..cn], .{});
    defer config_parsed.deinit();

    const container_config = config_parsed.value.object.get("config") orelse return error.InvalidImage;

    var result = ImageConfig{ .entrypoint = null, .cmd = null };

    if (container_config.object.get("Entrypoint")) |ep| {
        if (ep == .array) {
            var list: std.ArrayListUnmanaged([]const u8) = .{};
            for (ep.array.items) |item| {
                if (item == .string) try list.append(allocator, try allocator.dupe(u8, item.string));
            }
            if (list.items.len > 0) result.entrypoint = try list.toOwnedSlice(allocator);
        }
    }

    if (container_config.object.get("Cmd")) |cmd| {
        if (cmd == .array) {
            var list: std.ArrayListUnmanaged([]const u8) = .{};
            for (cmd.array.items) |item| {
                if (item == .string) try list.append(allocator, try allocator.dupe(u8, item.string));
            }
            if (list.items.len > 0) result.cmd = try list.toOwnedSlice(allocator);
        }
    }

    return result;
}

fn extractOciLayout(allocator: std.mem.Allocator, layout_path: []const u8, rootfs_dir: []const u8) !void {
    const index_path = try std.fmt.allocPrint(allocator, "{s}/index.json", .{layout_path});
    defer allocator.free(index_path);

    const index_file = try std.fs.openFileAbsolute(index_path, .{});
    defer index_file.close();
    var index_buf: [16384]u8 = undefined;
    const n = try index_file.readAll(&index_buf);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, index_buf[0..n], .{});
    defer parsed.deinit();

    const manifests = parsed.value.object.get("manifests") orelse return error.InvalidImage;
    if (manifests.array.items.len == 0) return error.InvalidImage;
    const digest = manifests.array.items[0].object.get("digest") orelse return error.InvalidImage;

    const hash = digest.string[7..];
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/blobs/sha256/{s}", .{ layout_path, hash });
    defer allocator.free(manifest_path);

    const manifest_file = try std.fs.openFileAbsolute(manifest_path, .{});
    defer manifest_file.close();
    var manifest_buf: [65536]u8 = undefined;
    const mn = try manifest_file.readAll(&manifest_buf);
    const manifest_parsed = try std.json.parseFromSlice(std.json.Value, allocator, manifest_buf[0..mn], .{});
    defer manifest_parsed.deinit();

    const layers = manifest_parsed.value.object.get("layers") orelse return error.InvalidImage;

    for (layers.array.items) |layer_desc| {
        const layer_digest = layer_desc.object.get("digest") orelse continue;
        const media_type = layer_desc.object.get("mediaType") orelse continue;

        const layer_hash = layer_digest.string[7..];
        const layer_path = try std.fmt.allocPrint(allocator, "{s}/blobs/sha256/{s}", .{ layout_path, layer_hash });
        defer allocator.free(layer_path);

        const compression = layer.Compression.fromMediaType(media_type.string);
        layer.extractLayer(layer_path, compression, .{
            .target = rootfs_dir,
            .handle_whiteouts = true,
        }, allocator) catch |err| {
            scoped_log.err("Failed to extract layer: {}", .{err});
            return error.ExtractionFailed;
        };
    }
}

test "RunzOptions defaults" {
    const opts = RunzOptions{};
    try std.testing.expect(opts.rm);
    try std.testing.expect(!opts.rootless);
    try std.testing.expect(opts.network == .veth);
}
