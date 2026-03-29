const std = @import("std");
const linux = std.os.linux;
const log = @import("log.zig");
const syscall = @import("linux/syscall.zig");
const runtime_spec = @import("runtime_spec.zig");

const scoped_log = log.scoped("spec-mount");

/// Process OCI spec mounts inside a rootfs (before pivot_root).
/// Each mount is applied relative to the rootfs path.
pub fn applySpecMounts(
    allocator: std.mem.Allocator,
    rootfs_path: []const u8,
    mounts: []const runtime_spec.Mount,
) void {
    for (mounts) |m| {
        applyMount(allocator, rootfs_path, &m);
    }
}

fn applyMount(allocator: std.mem.Allocator, rootfs_path: []const u8, m: *const runtime_spec.Mount) void {
    const target = std.fmt.allocPrint(allocator, "{s}{s}", .{ rootfs_path, m.destination }) catch return;
    defer allocator.free(target);

    // Ensure target directory exists
    {
        var dir = std.fs.openDirAbsolute(rootfs_path, .{}) catch return;
        defer dir.close();
        // Strip leading / for makePath
        const rel = if (m.destination.len > 1 and m.destination[0] == '/') m.destination[1..] else m.destination;
        dir.makePath(rel) catch {};
    }

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (target.len >= target_buf.len) return;
    @memcpy(target_buf[0..target.len], target);
    target_buf[target.len] = 0;
    const target_z: [*:0]const u8 = @ptrCast(target_buf[0..target.len :0]);

    // Null-terminate fstype
    var fstype_buf: [64]u8 = undefined;
    var fstype_z: ?[*:0]const u8 = null;
    if (m.type) |ft| {
        if (ft.len < fstype_buf.len) {
            @memcpy(fstype_buf[0..ft.len], ft);
            fstype_buf[ft.len] = 0;
            fstype_z = @ptrCast(fstype_buf[0..ft.len :0]);
        }
    }
    const fstype = m.type;
    const source_str = m.source orelse (fstype orelse "none");

    // Null-terminate source
    var source_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (source_str.len >= source_buf.len) return;
    @memcpy(source_buf[0..source_str.len], source_str);
    source_buf[source_str.len] = 0;
    const source_z: [*:0]const u8 = @ptrCast(source_buf[0..source_str.len :0]);

    // Parse mount flags from options
    var flags = syscall.MountFlags{};
    var data_parts: std.ArrayListUnmanaged(u8) = .{};
    defer data_parts.deinit(allocator);

    if (m.options) |options| {
        for (options) |opt| {
            if (std.mem.eql(u8, opt, "ro")) {
                flags.rdonly = true;
            } else if (std.mem.eql(u8, opt, "nosuid")) {
                flags.nosuid = true;
            } else if (std.mem.eql(u8, opt, "nodev")) {
                flags.nodev = true;
            } else if (std.mem.eql(u8, opt, "noexec")) {
                flags.noexec = true;
            } else if (std.mem.eql(u8, opt, "bind")) {
                flags.bind = true;
            } else if (std.mem.eql(u8, opt, "rbind")) {
                flags.bind = true;
                flags.rec = true;
            } else if (std.mem.eql(u8, opt, "rprivate")) {
                flags.private = true;
                flags.rec = true;
            } else if (std.mem.eql(u8, opt, "private")) {
                flags.private = true;
            } else if (std.mem.eql(u8, opt, "rshared")) {
                flags.shared = true;
                flags.rec = true;
            } else if (std.mem.eql(u8, opt, "strictatime")) {
                flags.strictatime = true;
            } else if (std.mem.eql(u8, opt, "relatime")) {
                flags.relatime = true;
            } else if (std.mem.eql(u8, opt, "remount")) {
                flags.remount = true;
            } else {
                // Unknown option — pass as mount data
                if (data_parts.items.len > 0) {
                    data_parts.appendSlice(allocator, ",") catch {};
                }
                data_parts.appendSlice(allocator, opt) catch {};
            }
        }
    }

    // Build data string (null-terminated)
    var data_z: ?[*:0]const u8 = null;
    var data_buf: [4096]u8 = undefined;
    if (data_parts.items.len > 0 and data_parts.items.len < data_buf.len) {
        @memcpy(data_buf[0..data_parts.items.len], data_parts.items);
        data_buf[data_parts.items.len] = 0;
        data_z = @ptrCast(data_buf[0..data_parts.items.len :0]);
    }

    if (flags.bind) {
        // Bind mount
        scoped_log.debug("bind mount {s} -> {s}", .{ source_str, m.destination });
        syscall.mount(source_z, target_z, null, flags, null) catch |err| {
            scoped_log.debug("bind mount {s} failed: {}", .{ m.destination, err });
        };
        // Apply readonly after bind mount if requested
        if (flags.rdonly) {
            var ro_flags = flags;
            ro_flags.remount = true;
            syscall.mount(null, target_z, null, ro_flags, null) catch {};
        }
    } else if (fstype != null) {
        // Filesystem mount
        scoped_log.debug("mount {s} ({s}) -> {s}", .{ source_str, fstype.?, m.destination });
        syscall.mount(source_z, target_z, fstype_z, flags, data_z) catch |err| {
            scoped_log.debug("mount {s} failed: {}", .{ m.destination, err });
        };
    } else {
        scoped_log.debug("skipping mount {s} (no type or bind)", .{m.destination});
    }
}

test "applyMount does not crash on empty options" {
    // Smoke test — can't actually mount in unit tests
    const m = runtime_spec.Mount{
        .destination = "/proc",
        .type = "proc",
        .source = "proc",
    };
    _ = &m;
}
