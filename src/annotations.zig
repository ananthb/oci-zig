const std = @import("std");
const log = @import("log.zig");

const scoped_log = log.scoped("annotations");

/// Well-known OCI annotation keys (org.opencontainers.image.*)
pub const oci = struct {
    pub const created = "org.opencontainers.image.created";
    pub const authors = "org.opencontainers.image.authors";
    pub const url = "org.opencontainers.image.url";
    pub const documentation = "org.opencontainers.image.documentation";
    pub const source = "org.opencontainers.image.source";
    pub const version = "org.opencontainers.image.version";
    pub const revision = "org.opencontainers.image.revision";
    pub const vendor = "org.opencontainers.image.vendor";
    pub const licenses = "org.opencontainers.image.licenses";
    pub const ref_name = "org.opencontainers.image.ref.name";
    pub const title = "org.opencontainers.image.title";
    pub const description = "org.opencontainers.image.description";
    pub const base_name = "org.opencontainers.image.base.name";
    pub const base_digest = "org.opencontainers.image.base.digest";
};

/// A set of OCI annotations (string key -> string value map).
pub const Annotations = struct {
    entries: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Annotations {
        return .{
            .entries = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Annotations) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.entries.deinit();
    }

    /// Add or overwrite an annotation.
    pub fn put(self: *Annotations, key: []const u8, value: []const u8) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        const result = try self.entries.getOrPut(owned_key);
        if (result.found_existing) {
            // Free the old value and the duplicate key we just made
            self.allocator.free(result.value_ptr.*);
            self.allocator.free(owned_key);
            result.value_ptr.* = owned_value;
        } else {
            result.value_ptr.* = owned_value;
        }
    }

    /// Get an annotation value by key.
    pub fn get(self: *const Annotations, key: []const u8) ?[]const u8 {
        return self.entries.get(key);
    }

    /// Return the number of annotations.
    pub fn count(self: *const Annotations) usize {
        return self.entries.count();
    }
};

/// Parse annotations from a JSON object value.
/// Expects a std.json.Value that is an .object containing string->string pairs.
pub fn parseAnnotations(allocator: std.mem.Allocator, json_obj: std.json.Value) !Annotations {
    var annotations = Annotations.init(allocator);
    errdefer annotations.deinit();

    switch (json_obj) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                switch (entry.value_ptr.*) {
                    .string => |val| {
                        try annotations.put(key, val);
                    },
                    else => {
                        scoped_log.debug("Skipping non-string annotation: {s}", .{key});
                    },
                }
            }
        },
        .null => {
            // No annotations, return empty set
        },
        else => {
            scoped_log.warn("Expected object for annotations, got different type", .{});
        },
    }

    return annotations;
}

/// Merge overlay annotations into a base set.
/// Overlay values overwrite base values for the same key.
pub fn mergeAnnotations(base: *Annotations, overlay: *const Annotations) !void {
    var it = overlay.entries.iterator();
    while (it.next()) |entry| {
        try base.put(entry.key_ptr.*, entry.value_ptr.*);
    }
}

test "Annotations put and get" {
    const allocator = std.testing.allocator;
    var ann = Annotations.init(allocator);
    defer ann.deinit();

    try ann.put("key1", "value1");
    try ann.put("key2", "value2");

    try std.testing.expectEqualStrings("value1", ann.get("key1").?);
    try std.testing.expectEqualStrings("value2", ann.get("key2").?);
    try std.testing.expect(ann.get("key3") == null);
    try std.testing.expectEqual(@as(usize, 2), ann.count());
}

test "Annotations overwrite" {
    const allocator = std.testing.allocator;
    var ann = Annotations.init(allocator);
    defer ann.deinit();

    try ann.put("key", "old");
    try ann.put("key", "new");

    try std.testing.expectEqualStrings("new", ann.get("key").?);
    try std.testing.expectEqual(@as(usize, 1), ann.count());
}

test "mergeAnnotations" {
    const allocator = std.testing.allocator;
    var base = Annotations.init(allocator);
    defer base.deinit();
    var overlay = Annotations.init(allocator);
    defer overlay.deinit();

    try base.put("a", "1");
    try base.put("b", "2");
    try overlay.put("b", "3");
    try overlay.put("c", "4");

    try mergeAnnotations(&base, &overlay);

    try std.testing.expectEqualStrings("1", base.get("a").?);
    try std.testing.expectEqualStrings("3", base.get("b").?);
    try std.testing.expectEqualStrings("4", base.get("c").?);
}

test "well-known constants" {
    try std.testing.expectEqualStrings("org.opencontainers.image.title", oci.title);
    try std.testing.expectEqualStrings("org.opencontainers.image.version", oci.version);
}
