# runz

OCI container runtime and library in Zig.

## Technical Specifications

- **OCI Standards**: Implements the OCI runtime and image specifications.
- **Zig Implementation**: predictable performance and memory safety.
- **Daemonless**: Executes containers without a background process.
- **Library & CLI**: Provides a standalone binary and a Zig module for integration.

## Installation

### Prerequisites

- Zig 0.13.0 or later
- Linux (for runtime features)

### Using as a Library

Add `runz` to your `build.zig.zon`:

```zig
.dependencies = .{
    .runz = .{
        .url = "git+https://github.com/ananthb/runz",
        .hash = "...",
    },
},
```

In `build.zig`:

```zig
const runz_dep = b.dependency("runz", .{});
exe.root_module.addImport("runz", runz_dep.module("runz"));
```

## Basic Usage

### Pulling an Image

```zig
const std = @import("std");
const runz = @import("runz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var client = try runz.registry.RegistryClient.init(allocator, "registry-1.docker.io");
    defer client.deinit();

    try client.ensureAuth("library/alpine");
    const manifest = try client.fetchManifest("library/alpine", "latest", null);
}
```
