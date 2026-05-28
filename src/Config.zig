const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Direction = enum {
    horizontal,
    vertical,
};

pub const SizeMode = union(enum) {
    equal,
    percent: u8,
    fixed: u16,
};

pub const Mouse = enum {
    capture,
    passthrough,
};

pub const Restart = enum {
    never,
    on_failure,
};

pub const Pane = union(enum) {
    leaf: Leaf,
    split: Split,

    pub const Leaf = struct {
        command: []const []const u8,
        mouse: Mouse = .capture,
        restart: Restart = .never,
        size: SizeMode = .equal,
        name: []const u8 = "",
    };

    pub const Split = struct {
        direction: Direction,
        children: []const Pane,
        size: SizeMode = .equal,
    };
};

pub const Layout = struct {
    root: Pane,
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    // Unmanaged to avoid storing an allocator pointer that becomes
    // dangling when Config is moved (self-referential struct problem).
    layouts: std.StringArrayHashMapUnmanaged(Layout),
    prefix_key: u8 = 0x13, // Ctrl+S default
    pane_gap: u16 = 1,
    bindings: []const @import("input.zig").Binding = &.{},

    pub fn deinit(self: *Config) void {
        self.layouts.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    pub fn getLayout(self: *const Config, name: []const u8) ?*const Layout {
        return self.layouts.getPtr(name);
    }

    /// Resolve a layout by optional name.
    /// If name is null, looks up "default". Errors if not found.
    pub fn resolveLayout(self: *const Config, name: ?[]const u8) error{ NoDefaultLayout, LayoutNotFound }!*const Layout {
        const lookup_name = name orelse "default";
        if (self.layouts.getPtr(lookup_name)) |layout| {
            return layout;
        }
        if (name == null) return error.NoDefaultLayout;
        return error.LayoutNotFound;
    }
};

/// ZON-facing types: flat structs for a clean config file format.
/// These are parsed by std.zon and then converted to the typed Pane union.
pub const ZonPane = struct {
    // Leaf fields (present when this pane runs a command)
    command: ?[]const []const u8 = null,
    mouse: Mouse = .capture,
    restart: Restart = .never,
    name: []const u8 = "",

    // Split fields (present when this pane contains children)
    direction: ?Direction = null,
    children: ?[]const ZonPane = null,

    // Common
    size: SizeMode = .equal,
};

pub const ZonNamedLayout = struct {
    name: []const u8,
    root: ZonPane,
};

pub const ZonBinding = struct {
    key: []const u8,
    action: []const u8,
};

pub const ZonConfig = struct {
    prefix_key: ?[]const u8 = null,
    pane_gap: ?u16 = null,
    layouts: []const ZonNamedLayout,
    keymaps: ?[]const ZonBinding = null,
};

pub const ParseError = error{
    LeafAndSplit,
    NeitherLeafNorSplit,
    DirectionWithoutChildren,
    ChildrenWithoutDirection,
    EmptyCommand,
    EmptyChildren,
    OutOfMemory,
    ParseZon,
    ReadFileFailed,
};

/// Convert a ZonPane (flat struct from ZON) to a typed Pane (tagged union).
pub fn convertPane(allocator: Allocator, zp: ZonPane) ParseError!Pane {
    const has_command = zp.command != null;
    const has_direction = zp.direction != null;
    const has_children = zp.children != null;

    if (has_command and (has_direction or has_children)) return error.LeafAndSplit;
    if (has_direction and !has_children) return error.DirectionWithoutChildren;
    if (has_children and !has_direction) return error.ChildrenWithoutDirection;

    if (has_command) {
        if (zp.command.?.len == 0) return error.EmptyCommand;
        return .{ .leaf = .{
            .command = zp.command.?,
            .mouse = zp.mouse,
            .restart = zp.restart,
            .size = zp.size,
            .name = zp.name,
        } };
    }

    if (has_direction) {
        const zon_children = zp.children.?;
        if (zon_children.len == 0) return error.EmptyChildren;
        var children = try allocator.alloc(Pane, zon_children.len);
        for (zon_children, 0..) |child, i| {
            children[i] = try convertPane(allocator, child);
        }
        return .{ .split = .{
            .direction = zp.direction.?,
            .children = children,
            .size = zp.size,
        } };
    }

    return error.NeitherLeafNorSplit;
}

/// Parse a ZON config string into a Config.
/// The returned Config owns all memory via its internal arena.
pub fn parseFromSlice(backing_allocator: Allocator, source: [:0]const u8) ParseError!Config {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    // Parse ZON into intermediate types. Use arena so data lives with Config.
    const zon_config = std.zon.parse.fromSlice(ZonConfig, alloc, source, null, .{}) catch return error.ParseZon;
    // ZON data is allocated in arena — no need to free explicitly.

    var layouts = std.StringArrayHashMapUnmanaged(Layout){};
    errdefer layouts.deinit(alloc);

    for (zon_config.layouts) |named| {
        const root = try convertPane(alloc, named.root);
        layouts.put(alloc, named.name, .{ .root = root }) catch return error.OutOfMemory;
    }

    const input_mod = @import("input.zig");
    var prefix_key: u8 = 0x13; // default Ctrl+S
    if (zon_config.prefix_key) |pk_str| {
        if (input_mod.InputHandler.parseCtrlKey(pk_str)) |pk| {
            prefix_key = pk;
        }
    }

    // Parse keymaps if provided.
    var bindings: []const input_mod.Binding = &.{};
    if (zon_config.keymaps) |km| {
        var list = std.ArrayListUnmanaged(input_mod.Binding){};
        errdefer list.deinit(alloc);

        for (km) |zb| {
            if (input_mod.parseKey(alloc, zb.key)) |seq| {
                if (input_mod.parseAction(zb.action)) |action| {
                    try list.append(alloc, .{ .action = action, .sequence = seq });
                }
            }
        }

        bindings = list.items;
    }

    return .{ .arena = arena, .layouts = layouts, .prefix_key = prefix_key, .pane_gap = zon_config.pane_gap orelse 1, .bindings = bindings };
}

/// Read and parse a ZON config file from the given path.
pub fn parseFile(allocator: Allocator, path: []const u8) ParseError!Config {
    const file = std.fs.cwd().openFile(path, .{}) catch return error.ReadFileFailed;
    defer file.close();

    const stat = file.stat() catch return error.ReadFileFailed;
    const source = allocator.allocSentinel(u8, stat.size, 0) catch return error.OutOfMemory;
    defer allocator.free(source);

    const bytes_read = file.readAll(source) catch return error.ReadFileFailed;
    if (bytes_read != stat.size) return error.ReadFileFailed;

    return parseFromSlice(allocator, source);
}

/// Returns the config file path.
/// Checks the ZYOUZ_CONFIG env var first; falls back to ~/.config/zyouz/config.zon.
pub fn defaultConfigPath(allocator: Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "ZYOUZ_CONFIG")) |path| {
        return path;
    } else |_| {}
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return error.OutOfMemory;
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.config/zyouz/config.zon", .{home});
}

/// Print a layout tree for debugging (exit criteria: print parsed tree to stdout).
pub fn printTree(writer: anytype, pane: Pane, indent: usize) !void {
    const pad = "                                " ** 4;
    const prefix = pad[0..@min(indent * 2, pad.len)];

    switch (pane) {
        .leaf => |leaf| {
            try writer.print("{s}leaf:", .{prefix});
            for (leaf.command) |arg| {
                try writer.print(" {s}", .{arg});
            }
            if (leaf.name.len > 0) try writer.print(" [name={s}]", .{leaf.name});
            if (leaf.mouse != .capture) try writer.print(" [mouse={s}]", .{@tagName(leaf.mouse)});
            if (leaf.restart != .never) try writer.print(" [restart={s}]", .{@tagName(leaf.restart)});
            switch (leaf.size) {
                .equal => {},
                .percent => |p| try writer.print(" [size={d}%]", .{p}),
                .fixed => |f| try writer.print(" [size={d}]", .{f}),
            }
            try writer.writeAll("\n");
        },
        .split => |split| {
            try writer.print("{s}split({s}):\n", .{ prefix, @tagName(split.direction) });
            for (split.children) |child| {
                try printTree(writer, child, indent + 1);
            }
        },
    }
}

// --- Tests ---

test "Pane.leaf has correct defaults" {
    const leaf = Pane{ .leaf = .{
        .command = &.{"bash"},
    } };
    try std.testing.expectEqual(Mouse.capture, leaf.leaf.mouse);
    try std.testing.expectEqual(Restart.never, leaf.leaf.restart);
    try std.testing.expectEqual(SizeMode.equal, leaf.leaf.size);
}

test "Pane.split holds direction and children" {
    const child1 = Pane{ .leaf = .{ .command = &.{"bash"} } };
    const child2 = Pane{ .leaf = .{ .command = &.{"vim"} } };
    const split = Pane{ .split = .{
        .direction = .horizontal,
        .children = &.{ child1, child2 },
    } };
    try std.testing.expectEqual(Direction.horizontal, split.split.direction);
    try std.testing.expectEqual(@as(usize, 2), split.split.children.len);
}

test "SizeMode variants" {
    const equal = SizeMode.equal;
    const percent = SizeMode{ .percent = 30 };
    const fixed = SizeMode{ .fixed = 80 };

    try std.testing.expectEqual(SizeMode.equal, equal);
    try std.testing.expectEqual(@as(u8, 30), percent.percent);
    try std.testing.expectEqual(@as(u16, 80), fixed.fixed);
}

test "Config.getLayout returns layout by name" {
    var config = Config{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .layouts = .{},
    };
    defer config.deinit();

    try config.layouts.put(config.arena.allocator(), "default", .{ .root = .{ .leaf = .{ .command = &.{"bash"} } } });

    const layout = config.getLayout("default");
    try std.testing.expect(layout != null);
}

test "Config.getLayout returns null for missing name" {
    var config = Config{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .layouts = .{},
    };
    defer config.deinit();

    const layout = config.getLayout("nonexistent");
    try std.testing.expect(layout == null);
}

test "convertPane: leaf pane from ZonPane" {
    const zp = ZonPane{ .command = &.{"bash"} };
    const pane = try convertPane(std.testing.allocator, zp);
    try std.testing.expectEqual(@as(usize, 1), pane.leaf.command.len);
    try std.testing.expectEqualStrings("bash", pane.leaf.command[0]);
    try std.testing.expectEqual(Mouse.capture, pane.leaf.mouse);
}

test "convertPane: split pane from ZonPane" {
    const zp = ZonPane{
        .direction = .horizontal,
        .children = &.{
            ZonPane{ .command = &.{"bash"} },
            ZonPane{ .command = &.{"vim"} },
        },
    };
    const pane = try convertPane(std.testing.allocator, zp);
    defer std.testing.allocator.free(pane.split.children);
    try std.testing.expectEqual(Direction.horizontal, pane.split.direction);
    try std.testing.expectEqual(@as(usize, 2), pane.split.children.len);
}

test "convertPane: error when both command and direction set" {
    const zp = ZonPane{
        .command = &.{"bash"},
        .direction = .horizontal,
        .children = &.{ZonPane{ .command = &.{"vim"} }},
    };
    try std.testing.expectError(error.LeafAndSplit, convertPane(std.testing.allocator, zp));
}

test "convertPane: error when neither command nor direction set" {
    const zp = ZonPane{};
    try std.testing.expectError(error.NeitherLeafNorSplit, convertPane(std.testing.allocator, zp));
}

test "convertPane: error when direction without children" {
    const zp = ZonPane{ .direction = .vertical };
    try std.testing.expectError(error.DirectionWithoutChildren, convertPane(std.testing.allocator, zp));
}

test "convertPane: error when children without direction" {
    const zp = ZonPane{ .children = &.{ZonPane{ .command = &.{"bash"} }} };
    try std.testing.expectError(error.ChildrenWithoutDirection, convertPane(std.testing.allocator, zp));
}

test "convertPane: error when command is empty" {
    const zp = ZonPane{ .command = &.{} };
    try std.testing.expectError(error.EmptyCommand, convertPane(std.testing.allocator, zp));
}

test "convertPane: error when split has no children" {
    const zp = ZonPane{ .direction = .horizontal, .children = &.{} };
    try std.testing.expectError(error.EmptyChildren, convertPane(std.testing.allocator, zp));
}

test "parseFromSlice: single leaf layout" {
    const source =
        \\.{
        \\    .layouts = .{
        \\        .{
        \\            .name = "default",
        \\            .root = .{ .command = .{"bash"} },
        \\        },
        \\    },
        \\}
    ;
    var config = try parseFromSlice(std.testing.allocator, source);
    defer config.deinit();

    const layout = config.getLayout("default");
    try std.testing.expect(layout != null);
    const cmd = layout.?.root.leaf.command;
    try std.testing.expectEqual(@as(usize, 1), cmd.len);
    try std.testing.expectEqualStrings("bash", cmd[0]);
}

test "parseFromSlice: split layout with two children" {
    const source =
        \\.{
        \\    .layouts = .{
        \\        .{
        \\            .name = "dev",
        \\            .root = .{
        \\                .direction = .horizontal,
        \\                .children = .{
        \\                    .{ .command = .{"nvim"} },
        \\                    .{ .command = .{"bash"} },
        \\                },
        \\            },
        \\        },
        \\    },
        \\}
    ;
    var config = try parseFromSlice(std.testing.allocator, source);
    defer config.deinit();

    const layout = config.getLayout("dev");
    try std.testing.expect(layout != null);
    try std.testing.expectEqual(Direction.horizontal, layout.?.root.split.direction);
    try std.testing.expectEqual(@as(usize, 2), layout.?.root.split.children.len);
}

test "parseFromSlice: multiple named layouts" {
    const source =
        \\.{
        \\    .layouts = .{
        \\        .{
        \\            .name = "default",
        \\            .root = .{ .command = .{"bash"} },
        \\        },
        \\        .{
        \\            .name = "dev",
        \\            .root = .{ .command = .{"vim"} },
        \\        },
        \\    },
        \\}
    ;
    var config = try parseFromSlice(std.testing.allocator, source);
    defer config.deinit();

    try std.testing.expect(config.getLayout("default") != null);
    try std.testing.expect(config.getLayout("dev") != null);
    try std.testing.expect(config.getLayout("nonexistent") == null);
}

test "parseFromSlice: invalid ZON returns ParseZon error" {
    try std.testing.expectError(error.ParseZon, parseFromSlice(std.testing.allocator, "not valid zon"));
}

test "parseFile: non-existent file returns ReadFileFailed" {
    try std.testing.expectError(error.ReadFileFailed, parseFile(std.testing.allocator, "/tmp/zyouz-nonexistent-config.zon"));
}

test "parseFile: reads and parses a ZON file" {
    // Write a temp config file.
    const path = "/tmp/zyouz-test-config.zon";
    const content =
        \\.{
        \\    .layouts = .{
        \\        .{
        \\            .name = "default",
        \\            .root = .{ .command = .{"bash"} },
        \\        },
        \\    },
        \\}
    ;
    {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(content);
    }
    defer std.fs.cwd().deleteFile(path) catch {};

    var config = try parseFile(std.testing.allocator, path);
    defer config.deinit();

    try std.testing.expect(config.getLayout("default") != null);
}

test "printTree: leaf pane output" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const pane = Pane{ .leaf = .{ .command = &.{ "npm", "run", "dev" } } };
    try printTree(fbs.writer(), pane, 0);
    try std.testing.expectEqualStrings("leaf: npm run dev\n", fbs.getWritten());
}

test "printTree: leaf pane with name" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const pane = Pane{ .leaf = .{ .command = &.{"bash"}, .name = "editor" } };
    try printTree(fbs.writer(), pane, 0);
    try std.testing.expectEqualStrings("leaf: bash [name=editor]\n", fbs.getWritten());
}

test "printTree: split pane output" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const pane = Pane{ .split = .{
        .direction = .horizontal,
        .children = &.{
            Pane{ .leaf = .{ .command = &.{"vim"} } },
            Pane{ .leaf = .{ .command = &.{"bash"} } },
        },
    } };
    try printTree(fbs.writer(), pane, 0);
    const expected =
        \\split(horizontal):
        \\  leaf: vim
        \\  leaf: bash
        \\
    ;
    try std.testing.expectEqualStrings(expected, fbs.getWritten());
}

test "resolveLayout: returns default layout when no name given" {
    const source =
        \\.{
        \\    .layouts = .{
        \\        .{
        \\            .name = "default",
        \\            .root = .{ .command = .{"bash"} },
        \\        },
        \\    },
        \\}
    ;
    var config = try parseFromSlice(std.testing.allocator, source);
    defer config.deinit();

    const layout = try config.resolveLayout(null);
    try std.testing.expectEqualStrings("bash", layout.root.leaf.command[0]);
}

test "resolveLayout: returns named layout" {
    const source =
        \\.{
        \\    .layouts = .{
        \\        .{
        \\            .name = "dev",
        \\            .root = .{ .command = .{"vim"} },
        \\        },
        \\    },
        \\}
    ;
    var config = try parseFromSlice(std.testing.allocator, source);
    defer config.deinit();

    const layout = try config.resolveLayout("dev");
    try std.testing.expectEqualStrings("vim", layout.root.leaf.command[0]);
}

test "resolveLayout: error when no name given and no default layout" {
    const source =
        \\.{
        \\    .layouts = .{
        \\        .{
        \\            .name = "dev",
        \\            .root = .{ .command = .{"vim"} },
        \\        },
        \\    },
        \\}
    ;
    var config = try parseFromSlice(std.testing.allocator, source);
    defer config.deinit();

    try std.testing.expectError(error.NoDefaultLayout, config.resolveLayout(null));
}

test "resolveLayout: error when named layout not found" {
    const source =
        \\.{
        \\    .layouts = .{
        \\        .{
        \\            .name = "default",
        \\            .root = .{ .command = .{"bash"} },
        \\        },
        \\    },
        \\}
    ;
    var config = try parseFromSlice(std.testing.allocator, source);
    defer config.deinit();

    try std.testing.expectError(error.LayoutNotFound, config.resolveLayout("nonexistent"));
}

const c_env = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
};

test "defaultConfigPath: falls back to ~/.config/zyouz/config.zon when ZYOUZ_CONFIG is not set" {
    // Save and clear ZYOUZ_CONFIG so the test is env-independent.
    const saved = c_env.getenv("ZYOUZ_CONFIG");
    _ = c_env.unsetenv("ZYOUZ_CONFIG");
    defer if (saved) |s| {
        _ = c_env.setenv("ZYOUZ_CONFIG", s, 1);
    };

    const path = try defaultConfigPath(std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "/.config/zyouz/config.zon"));
}

test "defaultConfigPath: ZYOUZ_CONFIG overrides default path" {
    _ = c_env.setenv("ZYOUZ_CONFIG", "/custom/path/config.zon", 1);
    defer _ = c_env.unsetenv("ZYOUZ_CONFIG");

    const path = try defaultConfigPath(std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/custom/path/config.zon", path);
}

test "parseFromSlice: prefix_key is parsed" {
    const source =
        \\.{
        \\    .prefix_key = "ctrl-b",
        \\    .layouts = .{
        \\        .{
        \\            .name = "default",
        \\            .root = .{ .command = .{"bash"} },
        \\        },
        \\    },
        \\}
    ;
    var config = try parseFromSlice(std.testing.allocator, source);
    defer config.deinit();

    try std.testing.expectEqual(@as(u8, 0x02), config.prefix_key);
}

test "parseFromSlice: pane_gap is parsed" {
    const source =
        \\.{
        \\    .pane_gap = 2,
        \\    .layouts = .{
        \\        .{
        \\            .name = "default",
        \\            .root = .{ .command = .{"bash"} },
        \\        },
        \\    },
        \\}
    ;
    var config = try parseFromSlice(std.testing.allocator, source);
    defer config.deinit();

    try std.testing.expectEqual(@as(u16, 2), config.pane_gap);
}

test "parseFromSlice: default pane_gap is 1 when not specified" {
    const source =
        \\.{
        \\    .layouts = .{
        \\        .{
        \\            .name = "default",
        \\            .root = .{ .command = .{"bash"} },
        \\        },
        \\    },
        \\}
    ;
    var config = try parseFromSlice(std.testing.allocator, source);
    defer config.deinit();

    try std.testing.expectEqual(@as(u16, 1), config.pane_gap);
}

test "parseFromSlice: default prefix_key is Ctrl+S when not specified" {
    const source =
        \\.{
        \\    .layouts = .{
        \\        .{
        \\            .name = "default",
        \\            .root = .{ .command = .{"bash"} },
        \\        },
        \\    },
        \\}
    ;
    var config = try parseFromSlice(std.testing.allocator, source);
    defer config.deinit();

    try std.testing.expectEqual(@as(u8, 0x13), config.prefix_key);
}

test "convertPane: leaf pane preserves name field" {
    const zp = ZonPane{ .command = &.{"bash"}, .name = "editor" };
    const pane = try convertPane(std.testing.allocator, zp);
    try std.testing.expectEqualStrings("editor", pane.leaf.name);
}

test "convertPane: leaf pane name defaults to empty string" {
    const zp = ZonPane{ .command = &.{"bash"} };
    const pane = try convertPane(std.testing.allocator, zp);
    try std.testing.expectEqualStrings("", pane.leaf.name);
}

test "parseFromSlice: leaf with name field" {
    const source =
        \\.{
        \\    .layouts = .{
        \\        .{
        \\            .name = "default",
        \\            .root = .{ .command = .{"bash"}, .name = "editor" },
        \\        },
        \\    },
        \\}
    ;
    var config = try parseFromSlice(std.testing.allocator, source);
    defer config.deinit();

    const layout = config.getLayout("default");
    try std.testing.expect(layout != null);
    try std.testing.expectEqualStrings("editor", layout.?.root.leaf.name);
}

test "parseFromSlice: leaf without name defaults to empty" {
    const source =
        \\.{
        \\    .layouts = .{
        \\        .{
        \\            .name = "default",
        \\            .root = .{ .command = .{"bash"} },
        \\        },
        \\    },
        \\}
    ;
    var config = try parseFromSlice(std.testing.allocator, source);
    defer config.deinit();

    const layout = config.getLayout("default");
    try std.testing.expect(layout != null);
    try std.testing.expectEqualStrings("", layout.?.root.leaf.name);
}

test "parseFromSlice: mixed named and unnamed panes in split" {
    const source =
        \\.{
        \\    .layouts = .{
        \\        .{
        \\            .name = "mixed",
        \\            .root = .{
        \\                .direction = .horizontal,
        \\                .children = .{
        \\                    .{ .command = .{"bash"}, .name = "named" },
        \\                    .{ .command = .{"bash"} },
        \\                    .{ .command = .{"bash"}, .name = "also-named" },
        \\                },
        \\            },
        \\        },
        \\    },
        \\}
    ;
    var config = try parseFromSlice(std.testing.allocator, source);
    defer config.deinit();

    const layout = config.getLayout("mixed");
    try std.testing.expect(layout != null);
    const children = layout.?.root.split.children;
    try std.testing.expectEqualStrings("named", children[0].leaf.name);
    try std.testing.expectEqualStrings("", children[1].leaf.name);
    try std.testing.expectEqualStrings("also-named", children[2].leaf.name);
}

test "parseFromSlice: nested split with names" {
    const source =
        \\.{
        \\    .layouts = .{
        \\        .{
        \\            .name = "dev",
        \\            .root = .{
        \\                .direction = .horizontal,
        \\                .children = .{
        \\                    .{ .command = .{"bash"}, .name = "editor", .size = .{ .percent = 60 } },
        \\                    .{
        \\                        .direction = .vertical,
        \\                        .children = .{
        \\                            .{ .command = .{"bash"}, .name = "server" },
        \\                            .{ .command = .{"bash"}, .name = "terminal" },
        \\                        },
        \\                    },
        \\                },
        \\            },
        \\        },
        \\    },
        \\}
    ;
    var config = try parseFromSlice(std.testing.allocator, source);
    defer config.deinit();

    const layout = config.getLayout("dev");
    try std.testing.expect(layout != null);
    const root = layout.?.root.split;
    try std.testing.expectEqualStrings("editor", root.children[0].leaf.name);
    const right = root.children[1].split;
    try std.testing.expectEqualStrings("server", right.children[0].leaf.name);
    try std.testing.expectEqualStrings("terminal", right.children[1].leaf.name);
}

test "parseFromSlice: keymaps are parsed" {
    const source =
        \\.{
        \\    .keymaps = .{
        \\        .{ .key = "ctrl-q", .action = "quit" },
        \\        .{ .key = "up", .action = "focus_up" },
        \\        .{ .key = "down", .action = "focus_down" },
        \\        .{ .key = "left", .action = "focus_left" },
        \\        .{ .key = "right", .action = "focus_right" },
        \\    },
        \\    .layouts = .{
        \\        .{
        \\            .name = "default",
        \\            .root = .{ .command = .{"bash"} },
        \\        },
        \\    },
        \\}
    ;
    var config = try parseFromSlice(std.testing.allocator, source);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 5), config.bindings.len);
    try std.testing.expectEqual(@import("input.zig").Action.quit, config.bindings[0].action);
    try std.testing.expectEqual(@as(usize, 1), config.bindings[0].sequence.len);
    try std.testing.expectEqual(@as(u8, 0x11), config.bindings[0].sequence[0]);
    try std.testing.expectEqual(@as(usize, 3), config.bindings[1].sequence.len);
    try std.testing.expectEqual(@as(u8, 0x1B), config.bindings[1].sequence[0]);
    try std.testing.expectEqual(@as(u8, '['), config.bindings[1].sequence[1]);
    try std.testing.expectEqual(@as(u8, 'A'), config.bindings[1].sequence[2]);
}

test "parseFromSlice: empty keymaps results in empty bindings" {
    const source =
        \\.{
        \\    .keymaps = .{},
        \\    .layouts = .{
        \\        .{
        \\            .name = "default",
        \\            .root = .{ .command = .{"bash"} },
        \\        },
        \\    },
        \\}
    ;
    var config = try parseFromSlice(std.testing.allocator, source);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 0), config.bindings.len);
}

test "parseFromSlice: no keymaps defaults to empty bindings" {
    const source =
        \\.{
        \\    .layouts = .{
        \\        .{
        \\            .name = "default",
        \\            .root = .{ .command = .{"bash"} },
        \\        },
        \\    },
        \\}
    ;
    var config = try parseFromSlice(std.testing.allocator, source);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 0), config.bindings.len);
}

test "parseFromSlice: custom keymaps override defaults" {
    const source =
        \\.{
        \\    .keymaps = .{
        \\        .{ .key = "ctrl-j", .action = "focus_down" },
        \\        .{ .key = "ctrl-k", .action = "focus_up" },
        \\    },
        \\    .layouts = .{
        \\        .{
        \\            .name = "default",
        \\            .root = .{ .command = .{"bash"} },
        \\        },
        \\    },
        \\}
    ;
    var config = try parseFromSlice(std.testing.allocator, source);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 2), config.bindings.len);
    try std.testing.expectEqual(@import("input.zig").Action.focus_down, config.bindings[0].action);
    try std.testing.expectEqual(@as(u8, 0x0A), config.bindings[0].sequence[0]); // Ctrl+J = 0x0A
    try std.testing.expectEqual(@import("input.zig").Action.focus_up, config.bindings[1].action);
    try std.testing.expectEqual(@as(u8, 0x0B), config.bindings[1].sequence[0]); // Ctrl+K = 0x0B
}

test "nested split layout structure" {
    const inner1 = Pane{ .leaf = .{
        .command = &.{ "npm", "run", "dev" },
        .restart = .on_failure,
    } };
    const inner2 = Pane{ .leaf = .{
        .command = &.{"bash"},
    } };
    const right = Pane{ .split = .{
        .direction = .vertical,
        .children = &.{ inner1, inner2 },
    } };
    const left = Pane{ .leaf = .{
        .command = &.{"nvim"},
        .mouse = .passthrough,
        .size = .{ .percent = 60 },
    } };
    const root = Pane{ .split = .{
        .direction = .horizontal,
        .children = &.{ left, right },
    } };

    try std.testing.expectEqual(Direction.horizontal, root.split.direction);
    try std.testing.expectEqual(@as(usize, 2), root.split.children.len);

    // left pane is a leaf with passthrough mouse
    try std.testing.expectEqual(Mouse.passthrough, root.split.children[0].leaf.mouse);
    try std.testing.expectEqual(@as(u8, 60), root.split.children[0].leaf.size.percent);

    // right pane is a split with vertical direction
    try std.testing.expectEqual(Direction.vertical, root.split.children[1].split.direction);
    try std.testing.expectEqual(Restart.on_failure, root.split.children[1].split.children[0].leaf.restart);
}
