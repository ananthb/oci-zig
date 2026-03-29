---
title: Basic Usage
description: Simple examples of how to use runz in your Zig project.
---

### Pulling an image

```zig
const std = @import("std");
const runz = @import("runz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Pull alpine:latest
    var client = try runz.registry.RegistryClient.init(allocator, "registry-1.docker.io");
    defer client.deinit();

    try client.ensureAuth("library/alpine");
    const manifest = try client.fetchManifest("library/alpine", "latest", null);
    
    std.debug.print("Pulled alpine with digest: {s}\n", .{manifest.config.digest});
}
```
