const std = @import("std");
const build_options = @import("build_options");
const zyouz = @import("zyouz");

const Config = zyouz.Config;
const Layout = zyouz.Layout;
const Pane = zyouz.Pane;
const Renderer = zyouz.Renderer;

pub const version = build_options.version;

const CliAction = union(enum) {
    version,
    help,
    run: ?[]const u8,
};

fn parseArgs(args: []const [:0]const u8) CliAction {
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            return .version;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .help;
        }
    }
    if (args.len > 1) {
        return .{ .run = args[1] };
    }
    return .{ .run = null };
}

fn configErrorMessage(err: Config.ParseError) []const u8 {
    return switch (err) {
        error.ParseZon => "syntax error in config file",
        error.ReadFileFailed => "could not read config file",
        error.EmptyCommand => "a pane has an empty command",
        error.EmptyChildren => "a split pane has no children",
        error.LeafAndSplit => "a pane has both 'command' and 'direction' (must be one or the other)",
        error.NeitherLeafNorSplit => "a pane has neither 'command' nor 'direction'",
        error.DirectionWithoutChildren => "a pane has 'direction' but no 'children'",
        error.ChildrenWithoutDirection => "a pane has 'children' but no 'direction'",
        error.OutOfMemory => "out of memory",
    };
}

const usage_text =
    \\Usage: zyouz [OPTIONS] [LAYOUT]
    \\
    \\A terminal multiplexer driven by a static config file.
    \\
    \\Arguments:
    \\  [LAYOUT]    Name of the layout to use (default: "default")
    \\
    \\Options:
    \\  -h, --help       Print this help message and exit
    \\  -v, --version    Print version and exit
    \\
;

fn collectLeaves(pane: Config.Pane, out: *std.ArrayListUnmanaged(Config.Pane.Leaf)) !void {
    switch (pane) {
        .leaf => |leaf| try out.append(std.heap.page_allocator, leaf),
        .split => |split| {
            for (split.children) |child| {
                try collectLeaves(child, out);
            }
        },
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const action = parseArgs(args);
    switch (action) {
        .version => {
            const stdout = std.fs.File.stdout();
            stdout.writeAll("zyouz " ++ version ++ "\n") catch {};
            return;
        },
        .help => {
            const stdout = std.fs.File.stdout();
            stdout.writeAll(usage_text) catch {};
            return;
        },
        .run => {},
    }

    const layout_name: ?[]const u8 = action.run;

    const config_path = try Config.defaultConfigPath(allocator);
    defer allocator.free(config_path);

    var config = Config.parseFile(allocator, config_path) catch |err| {
        std.debug.print("error: failed to load config from {s}\n", .{config_path});
        std.debug.print("  {s}\n", .{configErrorMessage(err)});
        std.process.exit(1);
    };
    defer config.deinit();

    const layout = config.resolveLayout(layout_name) catch |err| switch (err) {
        error.NoDefaultLayout => {
            std.debug.print("error: no 'default' layout found in {s}\n", .{config_path});
            std.process.exit(1);
        },
        error.LayoutNotFound => {
            std.debug.print("error: layout '{s}' not found in {s}\n", .{ layout_name.?, config_path });
            std.process.exit(1);
        },
    };

    var terminal = zyouz.Terminal.Terminal.init() catch |err| {
        if (err == error.NotATerminal) {
            std.debug.print("error: no controlling terminal (stdin is not a TTY)\n", .{});
            std.debug.print("hint: run the binary directly: ./zig-out/bin/zyouz\n", .{});
        }
        return err;
    };
    defer terminal.deinit();

    try terminal.enableRawMode();

    const size = try terminal.getSize();

    // Compute layout rects
    const area = Layout.Rect{ .col = 1, .row = 1, .width = size.cols -| 2, .height = size.rows -| 2 };
    const rects = try Layout.compute(allocator, layout.root, area, config.pane_gap);
    defer allocator.free(rects);

    // Collect leaf panes (depth-first order matches rect order)
    var leaves: std.ArrayListUnmanaged(Config.Pane.Leaf) = .empty;
    defer leaves.deinit(std.heap.page_allocator);
    try collectLeaves(layout.root, &leaves);

    if (leaves.items.len != rects.len) {
        std.debug.print("error: leaf count ({d}) != rect count ({d})\n", .{ leaves.items.len, rects.len });
        std.process.exit(1);
    }

    // Spawn panes (before alternate screen so errors are visible)
    var panes_buf: [32]Pane = undefined;
    const pane_count = @min(leaves.items.len, 32);
    for (0..pane_count) |i| {
        try panes_buf[i].initFromCommand(allocator, leaves.items[i].command, rects[i]);
        panes_buf[i].name = leaves.items[i].name;
        panes_buf[i].mouse_mode = leaves.items[i].mouse;
        panes_buf[i].restart = leaves.items[i].restart;
    }
    const panes = panes_buf[0..pane_count];
    defer {
        for (panes) |*p| p.deinit();
    }

    // Create renderer
    var renderer = try Renderer.init(allocator, size.cols, size.rows);
    defer renderer.deinit();

    // Make a mutable copy of rects for resize
    var mutable_rects_buf: [32]Layout.Rect = undefined;
    @memcpy(mutable_rects_buf[0..pane_count], rects[0..pane_count]);
    const mutable_rects = mutable_rects_buf[0..pane_count];

    // Now enter alternate screen — all fallible setup is done.
    try terminal.enterAlternateScreen();

    // Terminal restoration: declared AFTER pane/renderer setup so it runs
    // BEFORE their defers (Zig defers are LIFO). This ensures the terminal
    // is fully restored even if pane cleanup blocks on waitpid.
    defer {
        terminal.writeAll("\x1b[?25h\x1b[0m") catch {};
        terminal.leaveAlternateScreen() catch {};
        terminal.disableRawMode();
    }

    // Run multi-pane event loop
    var active_pane: usize = 0;
    zyouz.event_loop.runMultiPane(
        allocator,
        &terminal,
        panes,
        &renderer,
        mutable_rects,
        layout.root,
        &active_pane,
        config.prefix_key,
        config.pane_gap,
        config.exit_on_focus,
    ) catch {};
}

// --- Tests ---

test "parseArgs: --version returns version action" {
    const args: []const [:0]const u8 = &.{ "zyouz", "--version" };
    const action = parseArgs(args);
    try std.testing.expect(action == .version);
}

test "parseArgs: -v returns version action" {
    const args: []const [:0]const u8 = &.{ "zyouz", "-v" };
    const action = parseArgs(args);
    try std.testing.expect(action == .version);
}

test "parseArgs: --help returns help action" {
    const args: []const [:0]const u8 = &.{ "zyouz", "--help" };
    const action = parseArgs(args);
    try std.testing.expect(action == .help);
}

test "parseArgs: -h returns help action" {
    const args: []const [:0]const u8 = &.{ "zyouz", "-h" };
    const action = parseArgs(args);
    try std.testing.expect(action == .help);
}

test "parseArgs: layout name returns run action with name" {
    const args: []const [:0]const u8 = &.{ "zyouz", "dev" };
    const action = parseArgs(args);
    try std.testing.expectEqualStrings("dev", action.run.?);
}

test "parseArgs: no args returns run action with null" {
    const args: []const [:0]const u8 = &.{"zyouz"};
    const action = parseArgs(args);
    try std.testing.expect(action == .run);
    try std.testing.expect(action.run == null);
}

test "version: matches build options" {
    // Version is derived from build.zig.zon via build options.
    // This test verifies the build_options plumbing works.
    try std.testing.expect(version.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, version, ".") != null);
}

test "configErrorMessage: returns specific messages per error" {
    try std.testing.expectEqualStrings("syntax error in config file", configErrorMessage(error.ParseZon));
    try std.testing.expectEqualStrings("could not read config file", configErrorMessage(error.ReadFileFailed));
    try std.testing.expectEqualStrings("a pane has an empty command", configErrorMessage(error.EmptyCommand));
    try std.testing.expectEqualStrings("a split pane has no children", configErrorMessage(error.EmptyChildren));
    try std.testing.expectEqualStrings("out of memory", configErrorMessage(error.OutOfMemory));
}

test "usage_text: contains help and version flags" {
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "--help") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "--version") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "LAYOUT") != null);
}
