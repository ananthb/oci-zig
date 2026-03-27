const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ocispec_dep = b.dependency("ocispec", .{});
    const ocispec_module = ocispec_dep.module("ocispec");

    const oci_module = b.addModule("oci", .{
        .root_source_file = b.path("src/lib.zig"),
        .imports = &.{
            .{ .name = "ocispec", .module = ocispec_module },
        },
    });
    _ = oci_module;

    // Tests
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.addImport("ocispec", ocispec_module);
    const tests = b.addTest(.{
        .root_module = test_module,
    });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
