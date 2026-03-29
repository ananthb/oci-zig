---
title: Getting Started
description: How to install and use runz.
---

## Installation

### Prerequisites

- Zig 0.13.0 or later
- Linux (for runtime features)

### Using as a CLI

Clone the repository and build:

```sh
git clone https://github.com/ananthb/runz
cd runz
zig build -Doptimize=ReleaseSafe
```

The binary will be in `zig-out/bin/runz`.

### Using as a Library

Add `runz` to your `build.zig.zon`:

```zig
.dependencies = .{
    .runz = .{
        .url = "git+https://github.com/ananthb/runz",
        .hash = "...", // use your actual hash
    },
},
```

In `build.zig`:

```zig
const runz_dep = b.dependency("runz", .{});
exe.root_module.addImport("runz", runz_dep.module("runz"));
```

## Basic Usage

### Pull an image

```sh
./runz pull alpine:latest
```

### Run a container

```sh
./runz run alpine:latest echo "Hello from runz!"
```
