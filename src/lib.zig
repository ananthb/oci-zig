//! OCI library - container image operations for Zig
//!
//! Provides OCI spec types, registry client, image building,
//! Containerfile parsing, and layout reading/writing.

/// OCI spec types (image, runtime, distribution)
pub const spec = @import("ocispec");

/// OCI image reference parsing and types
pub const image = @import("image.zig");

/// Registry HTTP client (pull, auth, platform resolution)
pub const registry = @import("registry.zig");

/// Registry authentication (token fetching, WWW-Authenticate parsing)
pub const auth = @import("auth.zig");

/// Layer extraction and whiteout handling
pub const layer = @import("layer.zig");

/// Blob caching
pub const cache = @import("cache.zig");

/// OCI image layout writer
pub const layout_writer = @import("layout_writer.zig");

/// Containerfile/Dockerfile parser
pub const containerfile = @import("containerfile.zig");

/// Container command execution (RUN support via chroot)
pub const run = @import("run.zig");

/// Container lifecycle management (create, start, kill, delete)
pub const container = @import("container.zig");

/// OCI Runtime Spec (config.json parsing)
pub const runtime_spec = @import("runtime_spec.zig");

/// OCI lifecycle hooks
pub const hooks = @import("hooks.zig");

/// Daemonless container runner (like podman run)
pub const runz = @import("runz.zig");

/// Logging (set log level, colors)
pub const log = @import("log.zig");

/// Linux-specific utilities (namespaces, mounts, seccomp, cgroups, capabilities)
pub const linux_util = @import("linux.zig");
