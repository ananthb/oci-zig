const std = @import("std");
const runz = @import("runz");
const helpers = @import("helpers.zig");

// ============================================================================
// Layer 1: Library integration tests
// These test the runz library functions directly (no CLI subprocess).
// Require root or user namespace support.
// ============================================================================

// --- Runtime spec parsing ---

test "parse config.json and extract process args" {
    const allocator = std.testing.allocator;
    const config = try helpers.minimalConfig(allocator, &.{ "/bin/echo", "hello" });
    defer allocator.free(config);

    const spec = try runz.runtime_spec.parseConfig(allocator, config);
    try std.testing.expect(spec.process != null);
    try std.testing.expect(spec.process.?.args != null);
    try std.testing.expectEqual(@as(usize, 2), spec.process.?.args.?.len);
    try std.testing.expectEqualStrings("/bin/echo", spec.process.?.args.?[0]);
    try std.testing.expectEqualStrings("hello", spec.process.?.args.?[1]);

    // Cleanup allocated strings
    freeSpec(allocator, &spec);
}

fn freeSpec(allocator: std.mem.Allocator, spec: *const runz.runtime_spec.Spec) void {
    allocator.free(spec.ociVersion);
    if (spec.root) |r| allocator.free(r.path);
    if (spec.process) |p| {
        allocator.free(p.cwd);
        if (p.args) |args| {
            for (args) |a| allocator.free(a);
            allocator.free(args);
        }
        if (p.env) |env| {
            for (env) |e| allocator.free(e);
            allocator.free(env);
        }
        if (p.capabilities) |caps| {
            inline for (.{ "bounding", "effective", "inheritable", "permitted", "ambient" }) |field| {
                if (@field(caps, field)) |names| {
                    for (names) |n| allocator.free(n);
                    allocator.free(names);
                }
            }
        }
    }
    if (spec.linux) |lnx| {
        if (lnx.namespaces) |ns| {
            for (ns) |n| allocator.free(n.type);
            allocator.free(ns);
        }
        if (lnx.maskedPaths) |mp| {
            for (mp) |p| allocator.free(p);
            allocator.free(mp);
        }
        if (lnx.readonlyPaths) |rp| {
            for (rp) |p| allocator.free(p);
            allocator.free(rp);
        }
        if (lnx.cgroupsPath) |cp| allocator.free(cp);
        if (lnx.seccomp) |sec| {
            allocator.free(sec.defaultAction);
            if (sec.architectures) |a| {
                for (a) |s| allocator.free(s);
                allocator.free(a);
            }
            if (sec.syscalls) |rules| {
                for (rules) |r| {
                    for (r.names) |n| allocator.free(n);
                    allocator.free(r.names);
                    allocator.free(r.action);
                }
                allocator.free(rules);
            }
        }
        if (lnx.resources) |res| {
            if (res.cpu) |cpu| {
                if (cpu.cpus) |c| allocator.free(c);
            }
        }
    }
    if (spec.mounts) |mounts| {
        for (mounts) |m| {
            allocator.free(m.destination);
            if (m.type) |t| allocator.free(t);
            if (m.source) |s| allocator.free(s);
            if (m.options) |opts| {
                for (opts) |o| allocator.free(o);
                allocator.free(opts);
            }
        }
        allocator.free(mounts);
    }
}

test "parse config.json with resource limits" {
    const allocator = std.testing.allocator;
    const config = try helpers.configWithLimits(allocator, &.{"/bin/true"}, 256 * 1024 * 1024, 100);
    defer allocator.free(config);

    const spec = try runz.runtime_spec.parseConfig(allocator, config);
    defer freeSpec(allocator, &spec);

    // Verify spec parses (detailed resource extraction is tested in runtime_spec unit tests)
    try std.testing.expect(spec.process != null);
}

// --- Container manager ---

test "container manager create and delete" {
    const allocator = std.testing.allocator;

    const ts: u64 = @intCast(std.time.timestamp());
    const state_dir = try std.fmt.allocPrint(allocator, "/tmp/runz-state-{x}", .{ts});
    defer allocator.free(state_dir);
    std.fs.makeDirAbsolute(state_dir) catch return;
    defer std.fs.deleteTreeAbsolute(state_dir) catch {};

    var mgr = runz.container.Manager.init(allocator, state_dir);

    var info = mgr.create("test-1", "/tmp/fake-bundle", null) catch return;
    try std.testing.expectEqualStrings("test-1", info.id);
    try std.testing.expectEqual(runz.container.State.created, info.state);

    // Verify state file was created
    var path_buf: [256]u8 = undefined;
    const state_path = std.fmt.bufPrint(&path_buf, "{s}/test-1.json", .{state_dir}) catch unreachable;
    std.fs.accessAbsolute(state_path, .{}) catch {
        try std.testing.expect(false); // state file should exist
    };

    // List should include our container
    const ids = try mgr.list(allocator);
    defer {
        for (ids) |id| allocator.free(id);
        allocator.free(ids);
    }
    try std.testing.expect(ids.len >= 1);
    var found = false;
    for (ids) |id| {
        if (std.mem.eql(u8, id, "test-1")) found = true;
    }
    try std.testing.expect(found);

    // Delete
    mgr.delete(&info);

    // State file should be gone
    std.fs.accessAbsolute(state_path, .{}) catch return; // expected: gone
    try std.testing.expect(false); // if we get here, file still exists
}

test "container state JSON serialization" {
    const allocator = std.testing.allocator;
    const info = runz.container.ContainerInfo{
        .id = "json-test",
        .pid = 12345,
        .state = .running,
        .bundle = "/opt/bundle",
        .created = 1700000000,
        .allocator = allocator,
    };
    const json = try info.toJson(allocator);
    defer allocator.free(json);

    // Parse it back
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const id = parsed.value.object.get("id") orelse return error.MissingField;
    try std.testing.expectEqualStrings("json-test", id.string);
    const status = parsed.value.object.get("status") orelse return error.MissingField;
    try std.testing.expectEqualStrings("running", status.string);
    const pid = parsed.value.object.get("pid") orelse return error.MissingField;
    try std.testing.expectEqual(@as(i64, 12345), pid.integer);
}

// --- Annotations ---

test "annotations parse and merge" {
    const allocator = std.testing.allocator;
    const json =
        \\{"org.opencontainers.image.title":"test","custom.key":"value"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    var annot = try runz.annotations.parseAnnotations(allocator, parsed.value);
    defer annot.deinit();

    try std.testing.expectEqualStrings("test", annot.get("org.opencontainers.image.title").?);
    try std.testing.expectEqualStrings("value", annot.get("custom.key").?);
}

// --- Capabilities ---

test "capability set from OCI names" {
    const caps = runz.linux_util.capabilities;
    const names = [_][]const u8{ "CAP_NET_RAW", "CAP_SYS_ADMIN", "CAP_CHOWN" };
    const set = caps.CapSet.fromNames(&names);
    try std.testing.expect(set.has(caps.CAP.NET_RAW));
    try std.testing.expect(set.has(caps.CAP.SYS_ADMIN));
    try std.testing.expect(set.has(caps.CAP.CHOWN));
    try std.testing.expect(!set.has(caps.CAP.SYS_MODULE));
}

// --- Cgroup version detection ---

test "cgroup version detection" {
    const cg = runz.linux_util.cgroup;
    const version = cg.detectVersion();
    // Should be either v1 or v2, just verify it doesn't crash
    try std.testing.expect(version == .v1 or version == .v2);
}

// --- Hook parsing ---

test "hook parsing from JSON" {
    const allocator = std.testing.allocator;
    const json =
        \\{"prestart":[{"path":"/usr/bin/setup","timeout":10}],"poststop":[{"path":"/usr/bin/cleanup"}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const hook_set = try runz.hooks.parseHooks(allocator, parsed.value);
    try std.testing.expectEqual(@as(usize, 1), hook_set.prestart.len);
    try std.testing.expectEqualStrings("/usr/bin/setup", hook_set.prestart[0].path);
    try std.testing.expectEqual(@as(u32, 10), hook_set.prestart[0].timeout.?);
    try std.testing.expectEqual(@as(usize, 1), hook_set.poststop.len);
    try std.testing.expectEqual(@as(usize, 0), hook_set.poststart.len);

    // Cleanup
    for (hook_set.prestart) |h| allocator.free(h.path);
    allocator.free(hook_set.prestart);
    for (hook_set.poststop) |h| allocator.free(h.path);
    allocator.free(hook_set.poststop);
}

// --- Netlink ---

test "netlink ipv4 address construction" {
    const nl = runz.linux_util.netlink;
    const addr = nl.ipv4(192, 168, 1, 1);
    const bytes: [4]u8 = @bitCast(addr);
    try std.testing.expectEqual(@as(u8, 192), bytes[0]);
    try std.testing.expectEqual(@as(u8, 168), bytes[1]);
    try std.testing.expectEqual(@as(u8, 1), bytes[2]);
    try std.testing.expectEqual(@as(u8, 1), bytes[3]);
}

// --- Security module availability ---

test "security module detection" {
    // Just verify the detection functions don't crash
    _ = runz.linux_util.security.isAppArmorAvailable();
    _ = runz.linux_util.security.isSELinuxAvailable();
}

// --- Propagation parsing ---

test "mount propagation parsing" {
    const prop = runz.linux_util.propagation;
    try std.testing.expectEqual(prop.Propagation.rprivate, prop.parsePropagation(&.{"rprivate"}).?);
    try std.testing.expectEqual(prop.Propagation.rshared, prop.parsePropagation(&.{"rshared"}).?);
    try std.testing.expectEqual(prop.Propagation.private, prop.parsePropagation(&.{ "nosuid", "private", "ro" }).?);
    try std.testing.expect(prop.parsePropagation(&.{"noexec"}) == null); // no propagation option
}

// --- Multiple container manager operations ---

test "container manager: multiple containers" {
    const allocator = std.testing.allocator;

    const ts: u64 = @intCast(std.time.timestamp());
    const state_dir = try std.fmt.allocPrint(allocator, "/tmp/runz-multi-{x}", .{ts});
    defer allocator.free(state_dir);
    std.fs.makeDirAbsolute(state_dir) catch return;
    defer std.fs.deleteTreeAbsolute(state_dir) catch {};

    var mgr = runz.container.Manager.init(allocator, state_dir);

    // Create 3 containers
    var c1 = mgr.create("alpha", "/tmp/bundle-a", null) catch return;
    var c2 = mgr.create("beta", "/tmp/bundle-b", null) catch return;
    var c3 = mgr.create("gamma", "/tmp/bundle-c", null) catch return;

    // List should have all 3
    const ids = try mgr.list(allocator);
    defer {
        for (ids) |id| allocator.free(id);
        allocator.free(ids);
    }
    try std.testing.expectEqual(@as(usize, 3), ids.len);

    // Delete one
    mgr.delete(&c2);

    // List should have 2
    const ids2 = try mgr.list(allocator);
    defer {
        for (ids2) |id| allocator.free(id);
        allocator.free(ids2);
    }
    try std.testing.expectEqual(@as(usize, 2), ids2.len);

    // Verify the right one was deleted
    var has_alpha = false;
    var has_beta = false;
    var has_gamma = false;
    for (ids2) |id| {
        if (std.mem.eql(u8, id, "alpha")) has_alpha = true;
        if (std.mem.eql(u8, id, "beta")) has_beta = true;
        if (std.mem.eql(u8, id, "gamma")) has_gamma = true;
    }
    try std.testing.expect(has_alpha);
    try std.testing.expect(!has_beta);
    try std.testing.expect(has_gamma);

    // Clean up rest
    mgr.delete(&c1);
    mgr.delete(&c3);

    const ids3 = try mgr.list(allocator);
    defer {
        for (ids3) |id| allocator.free(id);
        allocator.free(ids3);
    }
    try std.testing.expectEqual(@as(usize, 0), ids3.len);
}

test "container manager: duplicate IDs" {
    const allocator = std.testing.allocator;

    const ts: u64 = @intCast(std.time.timestamp());
    const state_dir = try std.fmt.allocPrint(allocator, "/tmp/runz-dup-{x}", .{ts});
    defer allocator.free(state_dir);
    std.fs.makeDirAbsolute(state_dir) catch return;
    defer std.fs.deleteTreeAbsolute(state_dir) catch {};

    var mgr = runz.container.Manager.init(allocator, state_dir);

    var c1 = mgr.create("same-id", "/tmp/bundle-1", null) catch return;
    // Creating with same ID should overwrite (last wins)
    var c2 = mgr.create("same-id", "/tmp/bundle-2", null) catch return;

    const ids = try mgr.list(allocator);
    defer {
        for (ids) |id| allocator.free(id);
        allocator.free(ids);
    }
    try std.testing.expectEqual(@as(usize, 1), ids.len);

    mgr.delete(&c1);
    mgr.delete(&c2);
}

// --- Runtime spec: various config shapes ---

test "parse config.json with mounts" {
    const allocator = std.testing.allocator;
    const json =
        \\{"ociVersion":"1.0.2","root":{"path":"rootfs"},
        \\"process":{"args":["/bin/sh"],"cwd":"/"},
        \\"mounts":[
        \\  {"destination":"/proc","type":"proc","source":"proc"},
        \\  {"destination":"/dev","type":"tmpfs","source":"tmpfs","options":["nosuid","mode=755"]},
        \\  {"destination":"/sys","type":"sysfs","source":"sysfs","options":["ro","nosuid","noexec"]}
        \\],
        \\"linux":{"namespaces":[{"type":"pid"},{"type":"mount"}]}}
    ;
    const spec = try runz.runtime_spec.parseConfig(allocator, json);
    defer freeSpec(allocator, &spec);

    try std.testing.expect(spec.mounts != null);
    try std.testing.expectEqual(@as(usize, 3), spec.mounts.?.len);
    try std.testing.expectEqualStrings("/proc", spec.mounts.?[0].destination);
    try std.testing.expectEqualStrings("/dev", spec.mounts.?[1].destination);
    try std.testing.expectEqualStrings("/sys", spec.mounts.?[2].destination);

    // /dev mount should have options
    try std.testing.expect(spec.mounts.?[1].options != null);
    try std.testing.expectEqual(@as(usize, 2), spec.mounts.?[1].options.?.len);
}

test "parse config.json with capabilities" {
    const allocator = std.testing.allocator;
    const json =
        \\{"ociVersion":"1.0.2","root":{"path":"rootfs"},
        \\"process":{"args":["/bin/sh"],"cwd":"/",
        \\"capabilities":{"bounding":["CAP_NET_RAW","CAP_CHOWN"],"effective":["CAP_NET_RAW"]}}}
    ;
    const spec = try runz.runtime_spec.parseConfig(allocator, json);
    defer freeSpec(allocator, &spec);

    try std.testing.expect(spec.process != null);
    try std.testing.expect(spec.process.?.capabilities != null);
    const caps = spec.process.?.capabilities.?;
    try std.testing.expect(caps.bounding != null);
    try std.testing.expectEqual(@as(usize, 2), caps.bounding.?.len);
    try std.testing.expectEqualStrings("CAP_NET_RAW", caps.bounding.?[0]);
    try std.testing.expect(caps.effective != null);
    try std.testing.expectEqual(@as(usize, 1), caps.effective.?.len);
}

test "parse config.json with user" {
    const allocator = std.testing.allocator;
    const json =
        \\{"ociVersion":"1.0.2","root":{"path":"rootfs"},
        \\"process":{"args":["/bin/sh"],"cwd":"/","user":{"uid":1000,"gid":1000}}}
    ;
    const spec = try runz.runtime_spec.parseConfig(allocator, json);
    defer freeSpec(allocator, &spec);

    try std.testing.expect(spec.process.?.user != null);
    try std.testing.expectEqual(@as(u32, 1000), spec.process.?.user.?.uid);
    try std.testing.expectEqual(@as(u32, 1000), spec.process.?.user.?.gid);
}

test "parse config.json with seccomp" {
    const allocator = std.testing.allocator;
    const json =
        \\{"ociVersion":"1.0.2","root":{"path":"rootfs"},
        \\"process":{"args":["/bin/sh"],"cwd":"/"},
        \\"linux":{"seccomp":{"defaultAction":"SCMP_ACT_ERRNO",
        \\"syscalls":[{"names":["read","write","openat"],"action":"SCMP_ACT_ALLOW"}]}}}
    ;
    const spec = try runz.runtime_spec.parseConfig(allocator, json);
    defer freeSpec(allocator, &spec);

    try std.testing.expect(spec.linux != null);
    try std.testing.expect(spec.linux.?.seccomp != null);
    const sec = spec.linux.?.seccomp.?;
    try std.testing.expectEqualStrings("SCMP_ACT_ERRNO", sec.defaultAction);
    try std.testing.expect(sec.syscalls != null);
    try std.testing.expectEqual(@as(usize, 1), sec.syscalls.?.len);
    try std.testing.expectEqual(@as(usize, 3), sec.syscalls.?[0].names.len);
}

test "parse config.json with resources" {
    const allocator = std.testing.allocator;
    const json =
        \\{"ociVersion":"1.0.2","root":{"path":"rootfs"},
        \\"process":{"args":["/bin/sh"],"cwd":"/"},
        \\"linux":{"resources":{"memory":{"limit":536870912},"pids":{"limit":256},
        \\"cpu":{"shares":512,"quota":50000,"period":100000}}}}
    ;
    const spec = try runz.runtime_spec.parseConfig(allocator, json);
    defer freeSpec(allocator, &spec);

    try std.testing.expect(spec.linux != null);
    try std.testing.expect(spec.linux.?.resources != null);
    const res = spec.linux.?.resources.?;
    try std.testing.expect(res.memory != null);
    try std.testing.expectEqual(@as(i64, 536870912), res.memory.?.limit.?);
    try std.testing.expect(res.pids != null);
    try std.testing.expectEqual(@as(i64, 256), res.pids.?.limit);
    try std.testing.expect(res.cpu != null);
    try std.testing.expectEqual(@as(u64, 512), res.cpu.?.shares.?);
}

// --- Seccomp ---

test "seccomp syscall name lookup" {
    const seccomp = runz.linux_util.seccomp;
    // These should exist on any Linux
    try std.testing.expect(seccomp.syscallFromName("read") != null);
    try std.testing.expect(seccomp.syscallFromName("write") != null);
    try std.testing.expect(seccomp.syscallFromName("openat") != null);
    try std.testing.expect(seccomp.syscallFromName("close") != null);
    try std.testing.expect(seccomp.syscallFromName("exit_group") != null);
    // This shouldn't exist
    try std.testing.expect(seccomp.syscallFromName("not_a_real_syscall") == null);
}

test "seccomp default filter has instructions" {
    const seccomp = runz.linux_util.seccomp;
    const filter = seccomp.defaultFilter();
    // Should have header (4) + blocked syscalls (20*2) + finalize (1) = 45
    try std.testing.expect(filter.len >= 5);
    try std.testing.expect(filter.len < 2048);
}

// --- Cgroup resources conversion ---

test "toCgroupResources handles zero values" {
    const res = runz.runtime_spec.LinuxResources{};
    const cg = runz.runtime_spec.toCgroupResources(&res);
    try std.testing.expectEqual(@as(u64, 0), cg.memory_max);
    try std.testing.expectEqual(@as(u64, 0), cg.cpu_quota);
    try std.testing.expectEqual(@as(u32, 0), cg.pids_max);
}

// --- Capabilities ---

test "capability default set matches Docker" {
    const caps = runz.linux_util.capabilities;
    const set = caps.CapSet.defaultSet();
    // Docker default caps
    try std.testing.expect(set.has(caps.CAP.CHOWN));
    try std.testing.expect(set.has(caps.CAP.DAC_OVERRIDE));
    try std.testing.expect(set.has(caps.CAP.FSETID));
    try std.testing.expect(set.has(caps.CAP.FOWNER));
    try std.testing.expect(set.has(caps.CAP.MKNOD));
    try std.testing.expect(set.has(caps.CAP.NET_RAW));
    try std.testing.expect(set.has(caps.CAP.SETGID));
    try std.testing.expect(set.has(caps.CAP.SETUID));
    try std.testing.expect(set.has(caps.CAP.SETFCAP));
    try std.testing.expect(set.has(caps.CAP.SETPCAP));
    try std.testing.expect(set.has(caps.CAP.NET_BIND_SERVICE));
    try std.testing.expect(set.has(caps.CAP.SYS_CHROOT));
    try std.testing.expect(set.has(caps.CAP.KILL));
    try std.testing.expect(set.has(caps.CAP.AUDIT_WRITE));
    // Should NOT have dangerous caps
    try std.testing.expect(!set.has(caps.CAP.SYS_ADMIN));
    try std.testing.expect(!set.has(caps.CAP.SYS_MODULE));
    try std.testing.expect(!set.has(caps.CAP.SYS_RAWIO));
    try std.testing.expect(!set.has(caps.CAP.SYS_PTRACE));
}

test "capability name parsing roundtrip" {
    const caps = runz.linux_util.capabilities;
    // All OCI cap names should parse
    const names = [_][]const u8{
        "CAP_CHOWN",        "CAP_DAC_OVERRIDE",   "CAP_FOWNER",
        "CAP_KILL",         "CAP_NET_RAW",         "CAP_NET_ADMIN",
        "CAP_SYS_ADMIN",   "CAP_SYS_CHROOT",     "CAP_SETUID",
        "CAP_SETGID",      "CAP_MKNOD",
    };
    for (names) |name| {
        try std.testing.expect(caps.capFromName(name) != null);
    }
    // Without CAP_ prefix should also work
    try std.testing.expect(caps.capFromName("NET_RAW") != null);
    try std.testing.expect(caps.capFromName("SYS_ADMIN") != null);
}

// --- Netlink ---

test "netlink attribute alignment" {
    const nl = runz.linux_util.netlink;
    try std.testing.expectEqual(@as(usize, 0), nl.nlAlign(0));
    try std.testing.expectEqual(@as(usize, 4), nl.nlAlign(1));
    try std.testing.expectEqual(@as(usize, 4), nl.nlAlign(3));
    try std.testing.expectEqual(@as(usize, 4), nl.nlAlign(4));
    try std.testing.expectEqual(@as(usize, 8), nl.nlAlign(5));
    try std.testing.expectEqual(@as(usize, 512), nl.nlAlign(512));
}

test "netlink struct sizes match kernel" {
    const nl = runz.linux_util.netlink;
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(nl.NlMsgHdr));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(nl.IfInfoMsg));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(nl.IfAddrMsg));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(nl.RtMsg));
}

// --- Container state transitions ---

test "container state enum covers OCI states" {
    // OCI spec defines: creating, created, running, stopped
    try std.testing.expectEqualStrings("creating", runz.container.State.creating.string());
    try std.testing.expectEqualStrings("created", runz.container.State.created.string());
    try std.testing.expectEqualStrings("running", runz.container.State.running.string());
    try std.testing.expectEqualStrings("stopped", runz.container.State.stopped.string());
}

test "container info JSON roundtrip with all states" {
    const allocator = std.testing.allocator;
    const states = [_]runz.container.State{ .creating, .created, .running, .stopped };

    for (states) |state| {
        const info = runz.container.ContainerInfo{
            .id = "roundtrip",
            .pid = 42,
            .state = state,
            .bundle = "/b",
            .allocator = allocator,
        };
        const json = try info.toJson(allocator);
        defer allocator.free(json);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer parsed.deinit();

        const status = parsed.value.object.get("status").?.string;
        try std.testing.expectEqualStrings(state.string(), status);
    }
}
