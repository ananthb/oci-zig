const std = @import("std");

pub const Instruction = union(enum) {
    from: FromInstruction,
    copy: CopyInstruction,
    add: CopyInstruction,
    env: EnvInstruction,
    workdir: []const u8,
    entrypoint: []const []const u8,
    cmd: []const []const u8,
    label: LabelInstruction,
    arg: ArgInstruction,
    expose: []const u8,
    volume: []const u8,
    user: []const u8,
    stopsignal: []const u8,
};

pub const FromInstruction = struct {
    image: []const u8,
    alias: ?[]const u8 = null,
};

pub const CopyInstruction = struct {
    sources: []const []const u8,
    dest: []const u8,
    from: ?[]const u8 = null,
};

pub const EnvInstruction = struct {
    key: []const u8,
    value: []const u8,
};

pub const LabelInstruction = struct {
    key: []const u8,
    value: []const u8,
};

pub const ArgInstruction = struct {
    name: []const u8,
    default: ?[]const u8 = null,
};

pub const Containerfile = struct {
    instructions: []const Instruction,

    pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Containerfile {
        var instructions: std.ArrayListUnmanaged(Instruction) = .{};
        errdefer {
            for (instructions.items) |inst| freeInstruction(allocator, inst);
            instructions.deinit(allocator);
        }

        // Variable store for ARG/ENV expansion
        var variables: std.StringHashMapUnmanaged([]const u8) = .{};
        defer {
            var it = variables.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            variables.deinit(allocator);
        }

        // First pass: join line continuations
        const joined = try joinContinuations(allocator, content);
        defer allocator.free(joined);

        var lines = std.mem.splitScalar(u8, joined, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            if (line[0] == '#') continue;

            // Split into instruction keyword and rest
            const space_idx = std.mem.indexOfAny(u8, line, " \t") orelse continue;
            const keyword_raw = line[0..space_idx];
            const rest = std.mem.trim(u8, line[space_idx + 1 ..], " \t");

            // Uppercase the keyword for comparison
            var keyword_buf: [32]u8 = undefined;
            if (keyword_raw.len > keyword_buf.len) continue;
            const keyword = upperCase(keyword_raw, &keyword_buf);

            // Expand variables in rest (except for ARG)
            const expanded_rest = if (!std.mem.eql(u8, keyword, "ARG"))
                try expandVariables(allocator, rest, &variables)
            else
                try allocator.dupe(u8, rest);
            defer allocator.free(expanded_rest);

            if (std.mem.eql(u8, keyword, "FROM")) {
                const inst = try parseFrom(allocator, expanded_rest);
                try instructions.append(allocator, inst);
            } else if (std.mem.eql(u8, keyword, "COPY")) {
                const inst = try parseCopy(allocator, expanded_rest, false);
                try instructions.append(allocator, inst);
            } else if (std.mem.eql(u8, keyword, "ADD")) {
                const inst = try parseCopy(allocator, expanded_rest, true);
                try instructions.append(allocator, inst);
            } else if (std.mem.eql(u8, keyword, "ENV")) {
                const inst = try parseEnv(allocator, expanded_rest);
                // Store in variables for expansion
                const key_dup = try allocator.dupe(u8, inst.env.key);
                const val_dup = try allocator.dupe(u8, inst.env.value);
                const old = try variables.fetchPut(allocator, key_dup, val_dup);
                if (old) |o| {
                    allocator.free(o.key);
                    allocator.free(o.value);
                }
                try instructions.append(allocator, inst);
            } else if (std.mem.eql(u8, keyword, "WORKDIR")) {
                try instructions.append(allocator, .{ .workdir = try allocator.dupe(u8, expanded_rest) });
            } else if (std.mem.eql(u8, keyword, "ENTRYPOINT")) {
                const args = try parseExecOrShell(allocator, expanded_rest);
                try instructions.append(allocator, .{ .entrypoint = args });
            } else if (std.mem.eql(u8, keyword, "CMD")) {
                const args = try parseExecOrShell(allocator, expanded_rest);
                try instructions.append(allocator, .{ .cmd = args });
            } else if (std.mem.eql(u8, keyword, "LABEL")) {
                const inst = try parseLabel(allocator, expanded_rest);
                try instructions.append(allocator, inst);
            } else if (std.mem.eql(u8, keyword, "ARG")) {
                const inst = try parseArg(allocator, expanded_rest);
                // Store default in variables if present and not already set
                if (inst.arg.default) |def| {
                    if (!variables.contains(inst.arg.name)) {
                        const key_dup = try allocator.dupe(u8, inst.arg.name);
                        const val_dup = try allocator.dupe(u8, def);
                        try variables.put(allocator, key_dup, val_dup);
                    }
                }
                try instructions.append(allocator, inst);
            } else if (std.mem.eql(u8, keyword, "EXPOSE")) {
                try instructions.append(allocator, .{ .expose = try allocator.dupe(u8, expanded_rest) });
            } else if (std.mem.eql(u8, keyword, "VOLUME")) {
                try instructions.append(allocator, .{ .volume = try allocator.dupe(u8, expanded_rest) });
            } else if (std.mem.eql(u8, keyword, "USER")) {
                try instructions.append(allocator, .{ .user = try allocator.dupe(u8, expanded_rest) });
            } else if (std.mem.eql(u8, keyword, "STOPSIGNAL")) {
                try instructions.append(allocator, .{ .stopsignal = try allocator.dupe(u8, expanded_rest) });
            }
            // Unknown instructions are silently skipped
        }

        return .{ .instructions = try instructions.toOwnedSlice(allocator) };
    }

    pub fn parseFile(allocator: std.mem.Allocator, path: []const u8) !Containerfile {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        const stat = try file.stat();
        const content = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(content);
        const bytes_read = try file.readAll(content);
        return parse(allocator, content[0..bytes_read]);
    }

    pub fn deinit(self: *const Containerfile, allocator: std.mem.Allocator) void {
        for (self.instructions) |inst| freeInstruction(allocator, inst);
        allocator.free(self.instructions);
    }
};

fn freeInstruction(allocator: std.mem.Allocator, inst: Instruction) void {
    switch (inst) {
        .from => |f| {
            allocator.free(f.image);
            if (f.alias) |a| allocator.free(a);
        },
        .copy, .add => |c| {
            for (c.sources) |s| allocator.free(s);
            allocator.free(c.sources);
            allocator.free(c.dest);
            if (c.from) |f| allocator.free(f);
        },
        .env => |e| {
            allocator.free(e.key);
            allocator.free(e.value);
        },
        .workdir => |w| allocator.free(w),
        .entrypoint, .cmd => |args| {
            for (args) |a| allocator.free(a);
            allocator.free(args);
        },
        .label => |l| {
            allocator.free(l.key);
            allocator.free(l.value);
        },
        .arg => |a| {
            allocator.free(a.name);
            if (a.default) |d| allocator.free(d);
        },
        .expose => |e| allocator.free(e),
        .volume => |v| allocator.free(v),
        .user => |u| allocator.free(u),
        .stopsignal => |s| allocator.free(s),
    }
}

fn joinContinuations(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == '\\' and i + 1 < content.len and content[i + 1] == '\n') {
            try result.append(allocator, ' ');
            i += 2;
        } else if (content[i] == '\\' and i + 2 < content.len and content[i + 1] == '\r' and content[i + 2] == '\n') {
            try result.append(allocator, ' ');
            i += 3;
        } else {
            try result.append(allocator, content[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice(allocator);
}

fn upperCase(input: []const u8, buf: []u8) []const u8 {
    const len = @min(input.len, buf.len);
    for (input[0..len], 0..) |c, i| {
        buf[i] = std.ascii.toUpper(c);
    }
    return buf[0..len];
}

fn expandVariables(allocator: std.mem.Allocator, input: []const u8, variables: *const std.StringHashMapUnmanaged([]const u8)) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '$') {
            if (i + 1 < input.len and input[i + 1] == '{') {
                // ${VAR} form
                const end = std.mem.indexOfScalarPos(u8, input, i + 2, '}') orelse {
                    try result.append(allocator, input[i]);
                    i += 1;
                    continue;
                };
                const var_name = input[i + 2 .. end];
                if (variables.get(var_name)) |val| {
                    try result.appendSlice(allocator, val);
                }
                i = end + 1;
            } else if (i + 1 < input.len and (std.ascii.isAlphabetic(input[i + 1]) or input[i + 1] == '_')) {
                // $VAR form
                var end = i + 1;
                while (end < input.len and (std.ascii.isAlphanumeric(input[end]) or input[end] == '_')) {
                    end += 1;
                }
                const var_name = input[i + 1 .. end];
                if (variables.get(var_name)) |val| {
                    try result.appendSlice(allocator, val);
                }
                i = end;
            } else {
                try result.append(allocator, input[i]);
                i += 1;
            }
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice(allocator);
}

fn parseFrom(allocator: std.mem.Allocator, rest: []const u8) !Instruction {
    // FROM <image> [AS <name>]
    var parts_iter = std.mem.tokenizeAny(u8, rest, " \t");
    const image = parts_iter.next() orelse return error.InvalidInstruction;

    var alias: ?[]const u8 = null;
    if (parts_iter.next()) |maybe_as| {
        var as_buf: [4]u8 = undefined;
        const upper = upperCase(maybe_as, &as_buf);
        if (std.mem.eql(u8, upper, "AS")) {
            if (parts_iter.next()) |name| {
                alias = try allocator.dupe(u8, name);
            }
        }
    }

    return .{ .from = .{
        .image = try allocator.dupe(u8, image),
        .alias = alias,
    } };
}

fn parseCopy(allocator: std.mem.Allocator, rest: []const u8, is_add: bool) !Instruction {
    // COPY [--from=stage] <src>... <dst>
    var from_stage: ?[]const u8 = null;
    var actual_rest = rest;

    if (std.mem.startsWith(u8, rest, "--from=")) {
        const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        from_stage = try allocator.dupe(u8, rest[7..end]);
        if (end < rest.len) {
            actual_rest = std.mem.trim(u8, rest[end + 1 ..], " \t");
        } else {
            actual_rest = "";
        }
    }

    var parts: std.ArrayListUnmanaged([]const u8) = .{};
    defer parts.deinit(allocator);

    var iter = std.mem.tokenizeAny(u8, actual_rest, " \t");
    while (iter.next()) |part| {
        try parts.append(allocator, part);
    }

    if (parts.items.len < 2) {
        if (from_stage) |f| allocator.free(f);
        return error.InvalidInstruction;
    }

    const dest = try allocator.dupe(u8, parts.items[parts.items.len - 1]);
    var sources: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer {
        for (sources.items) |s| allocator.free(s);
        sources.deinit(allocator);
    }
    for (parts.items[0 .. parts.items.len - 1]) |s| {
        try sources.append(allocator, try allocator.dupe(u8, s));
    }

    const copy_inst = CopyInstruction{
        .sources = try sources.toOwnedSlice(allocator),
        .dest = dest,
        .from = from_stage,
    };

    if (is_add) {
        return .{ .add = copy_inst };
    } else {
        return .{ .copy = copy_inst };
    }
}

fn parseEnv(allocator: std.mem.Allocator, rest: []const u8) !Instruction {
    // ENV <key>=<value> or ENV <key> <value>
    if (std.mem.indexOfScalar(u8, rest, '=')) |eq_idx| {
        const key = std.mem.trim(u8, rest[0..eq_idx], " \t");
        var value = std.mem.trim(u8, rest[eq_idx + 1 ..], " \t");
        // Strip surrounding quotes if present
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }
        return .{ .env = .{
            .key = try allocator.dupe(u8, key),
            .value = try allocator.dupe(u8, value),
        } };
    } else {
        // Space-separated form: ENV key value
        const space_idx = std.mem.indexOfAny(u8, rest, " \t") orelse return error.InvalidInstruction;
        const key = rest[0..space_idx];
        const value = std.mem.trim(u8, rest[space_idx + 1 ..], " \t");
        return .{ .env = .{
            .key = try allocator.dupe(u8, key),
            .value = try allocator.dupe(u8, value),
        } };
    }
}

fn parseLabel(allocator: std.mem.Allocator, rest: []const u8) !Instruction {
    // LABEL <key>=<value>
    if (std.mem.indexOfScalar(u8, rest, '=')) |eq_idx| {
        const key = std.mem.trim(u8, rest[0..eq_idx], " \t\"");
        var value = std.mem.trim(u8, rest[eq_idx + 1 ..], " \t");
        // Strip surrounding quotes
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }
        return .{ .label = .{
            .key = try allocator.dupe(u8, key),
            .value = try allocator.dupe(u8, value),
        } };
    }
    return error.InvalidInstruction;
}

fn parseArg(allocator: std.mem.Allocator, rest: []const u8) !Instruction {
    // ARG <name>[=<default>]
    if (std.mem.indexOfScalar(u8, rest, '=')) |eq_idx| {
        const name = std.mem.trim(u8, rest[0..eq_idx], " \t");
        const default_val = std.mem.trim(u8, rest[eq_idx + 1 ..], " \t");
        return .{ .arg = .{
            .name = try allocator.dupe(u8, name),
            .default = try allocator.dupe(u8, default_val),
        } };
    } else {
        return .{ .arg = .{
            .name = try allocator.dupe(u8, std.mem.trim(u8, rest, " \t")),
            .default = null,
        } };
    }
}

fn parseExecOrShell(allocator: std.mem.Allocator, rest: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, rest, " \t");
    if (trimmed.len > 0 and trimmed[0] == '[') {
        // JSON exec form: ["cmd", "arg1", "arg2"]
        return parseJsonArray(allocator, trimmed);
    } else {
        // Shell form: cmd arg1 arg2 -> ["/bin/sh", "-c", "cmd arg1 arg2"]
        var args: std.ArrayListUnmanaged([]const u8) = .{};
        errdefer {
            for (args.items) |a| allocator.free(a);
            args.deinit(allocator);
        }
        try args.append(allocator, try allocator.dupe(u8, "/bin/sh"));
        try args.append(allocator, try allocator.dupe(u8, "-c"));
        try args.append(allocator, try allocator.dupe(u8, trimmed));
        return args.toOwnedSlice(allocator);
    }
}

fn parseJsonArray(allocator: std.mem.Allocator, input: []const u8) ![]const []const u8 {
    // Simple JSON array parser for ["str", "str", ...]
    var items: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer {
        for (items.items) |item| allocator.free(item);
        items.deinit(allocator);
    }

    // Find content between [ and ]
    const start = (std.mem.indexOfScalar(u8, input, '[') orelse return error.InvalidInstruction) + 1;
    const end = std.mem.lastIndexOfScalar(u8, input, ']') orelse return error.InvalidInstruction;
    const content = std.mem.trim(u8, input[start..end], " \t\n\r");

    if (content.len == 0) return items.toOwnedSlice(allocator);

    var i: usize = 0;
    while (i < content.len) {
        // Skip whitespace and commas
        while (i < content.len and (content[i] == ' ' or content[i] == '\t' or content[i] == ',' or content[i] == '\n' or content[i] == '\r')) {
            i += 1;
        }
        if (i >= content.len) break;

        if (content[i] == '"') {
            // Parse quoted string
            i += 1;
            var str: std.ArrayListUnmanaged(u8) = .{};
            errdefer str.deinit(allocator);

            while (i < content.len and content[i] != '"') {
                if (content[i] == '\\' and i + 1 < content.len) {
                    switch (content[i + 1]) {
                        '"' => try str.append(allocator, '"'),
                        '\\' => try str.append(allocator, '\\'),
                        'n' => try str.append(allocator, '\n'),
                        't' => try str.append(allocator, '\t'),
                        else => {
                            try str.append(allocator, content[i]);
                            try str.append(allocator, content[i + 1]);
                        },
                    }
                    i += 2;
                } else {
                    try str.append(allocator, content[i]);
                    i += 1;
                }
            }
            if (i < content.len) i += 1; // skip closing quote
            try items.append(allocator, try str.toOwnedSlice(allocator));
        } else {
            // Unquoted token
            const token_start = i;
            while (i < content.len and content[i] != ',' and content[i] != ']') {
                i += 1;
            }
            const token = std.mem.trim(u8, content[token_start..i], " \t");
            if (token.len > 0) {
                try items.append(allocator, try allocator.dupe(u8, token));
            }
        }
    }

    return items.toOwnedSlice(allocator);
}

// Tests

test "parse simple FROM+COPY+CMD" {
    const content =
        \\FROM alpine:latest
        \\COPY src/ /app/
        \\CMD ["./app"]
    ;

    const cf = try Containerfile.parse(std.testing.allocator, content);
    defer cf.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), cf.instructions.len);

    // FROM
    try std.testing.expectEqualStrings("alpine:latest", cf.instructions[0].from.image);
    try std.testing.expect(cf.instructions[0].from.alias == null);

    // COPY
    try std.testing.expectEqual(@as(usize, 1), cf.instructions[1].copy.sources.len);
    try std.testing.expectEqualStrings("src/", cf.instructions[1].copy.sources[0]);
    try std.testing.expectEqualStrings("/app/", cf.instructions[1].copy.dest);

    // CMD
    try std.testing.expectEqual(@as(usize, 1), cf.instructions[2].cmd.len);
    try std.testing.expectEqualStrings("./app", cf.instructions[2].cmd[0]);
}

test "ENV variable expansion" {
    const content =
        \\FROM alpine
        \\ENV APP_DIR=/opt/app
        \\WORKDIR ${APP_DIR}
        \\COPY . $APP_DIR
    ;

    const cf = try Containerfile.parse(std.testing.allocator, content);
    defer cf.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), cf.instructions.len);
    try std.testing.expectEqualStrings("/opt/app", cf.instructions[2].workdir);
    try std.testing.expectEqualStrings("/opt/app", cf.instructions[3].copy.dest);
}

test "line continuation" {
    const content =
        \\FROM alpine
        \\COPY file1 \
        \\file2 /dest/
    ;

    const cf = try Containerfile.parse(std.testing.allocator, content);
    defer cf.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), cf.instructions.len);
    try std.testing.expectEqual(@as(usize, 2), cf.instructions[1].copy.sources.len);
    try std.testing.expectEqualStrings("file1", cf.instructions[1].copy.sources[0]);
    try std.testing.expectEqualStrings("file2", cf.instructions[1].copy.sources[1]);
    try std.testing.expectEqualStrings("/dest/", cf.instructions[1].copy.dest);
}

test "JSON array parsing for ENTRYPOINT" {
    const content =
        \\FROM ubuntu
        \\ENTRYPOINT ["python3", "-u", "app.py"]
    ;

    const cf = try Containerfile.parse(std.testing.allocator, content);
    defer cf.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), cf.instructions.len);
    try std.testing.expectEqual(@as(usize, 3), cf.instructions[1].entrypoint.len);
    try std.testing.expectEqualStrings("python3", cf.instructions[1].entrypoint[0]);
    try std.testing.expectEqualStrings("-u", cf.instructions[1].entrypoint[1]);
    try std.testing.expectEqualStrings("app.py", cf.instructions[1].entrypoint[2]);
}

test "comments are skipped" {
    const content =
        \\# This is a comment
        \\FROM alpine
        \\# Another comment
        \\CMD ["sh"]
    ;

    const cf = try Containerfile.parse(std.testing.allocator, content);
    defer cf.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), cf.instructions.len);
    try std.testing.expectEqualStrings("alpine", cf.instructions[0].from.image);
}

test "ARG with default value" {
    const content =
        \\ARG VERSION=1.0
        \\FROM alpine
        \\LABEL version=${VERSION}
    ;

    const cf = try Containerfile.parse(std.testing.allocator, content);
    defer cf.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), cf.instructions.len);

    // ARG
    try std.testing.expectEqualStrings("VERSION", cf.instructions[0].arg.name);
    try std.testing.expectEqualStrings("1.0", cf.instructions[0].arg.default.?);

    // LABEL with expanded variable
    try std.testing.expectEqualStrings("version", cf.instructions[2].label.key);
    try std.testing.expectEqualStrings("1.0", cf.instructions[2].label.value);
}

test "shell form ENTRYPOINT" {
    const content =
        \\FROM alpine
        \\ENTRYPOINT python3 app.py
    ;

    const cf = try Containerfile.parse(std.testing.allocator, content);
    defer cf.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), cf.instructions.len);
    try std.testing.expectEqual(@as(usize, 3), cf.instructions[1].entrypoint.len);
    try std.testing.expectEqualStrings("/bin/sh", cf.instructions[1].entrypoint[0]);
    try std.testing.expectEqualStrings("-c", cf.instructions[1].entrypoint[1]);
    try std.testing.expectEqualStrings("python3 app.py", cf.instructions[1].entrypoint[2]);
}

test "FROM with AS alias" {
    const content =
        \\FROM golang:1.21 AS builder
    ;

    const cf = try Containerfile.parse(std.testing.allocator, content);
    defer cf.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), cf.instructions.len);
    try std.testing.expectEqualStrings("golang:1.21", cf.instructions[0].from.image);
    try std.testing.expectEqualStrings("builder", cf.instructions[0].from.alias.?);
}
