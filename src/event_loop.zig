const std = @import("std");
const posix = std.posix;
const Terminal = @import("Terminal.zig");
const Pty = @import("Pty.zig");
const input = @import("input.zig");
const Pane = @import("Pane.zig");
const Renderer = @import("Renderer.zig");
const Layout = @import("Layout.zig");
const Config = @import("Config.zig");
const MouseParser = @import("MouseParser.zig");

/// Signal pipe for SIGWINCH notification.
/// Written from signal handler, read from event loop.
var signal_pipe: [2]posix.fd_t = .{ -1, -1 };

fn sigwinchHandler(_: c_int) callconv(.c) void {
    // Async-signal-safe: write 1 byte to pipe.
    _ = posix.write(signal_pipe[1], "W") catch {};
}

pub fn installSignalHandler() !void {
    const pipe = try posix.pipe();
    signal_pipe = pipe;

    // Make read end non-blocking so poll() works correctly.
    const flags = try posix.fcntl(pipe[0], posix.F.GETFL, 0);
    const o_nonblock: usize = @intCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
    _ = try posix.fcntl(pipe[0], posix.F.SETFL, flags | o_nonblock);

    var sa: posix.Sigaction = .{
        .handler = .{ .handler = sigwinchHandler },
        .mask = posix.sigemptyset(),
        .flags = std.c.SA.RESTART,
    };
    posix.sigaction(posix.SIG.WINCH, &sa, null);
}

pub fn run(terminal: *Terminal.Terminal, pty: *Pty.Pty) !void {
    try installSignalHandler();
    defer {
        posix.close(signal_pipe[0]);
        posix.close(signal_pipe[1]);
    }

    var handler = input.InputHandler{};
    var buf: [4096]u8 = undefined;

    while (true) {
        // Poll: terminal input, PTY output, signal pipe.
        var fds = [_]posix.pollfd{
            .{ .fd = terminal.fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = pty.master_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = signal_pipe[0], .events = posix.POLL.IN, .revents = 0 },
        };

        _ = posix.poll(&fds, -1) catch |err| switch (err) {
            error.NetworkSubsystemFailed => return err,
            else => continue, // retry on EINTR
        };

        // Handle signal pipe (SIGWINCH).
        if (fds[2].revents & posix.POLL.IN != 0) {
            // Drain the pipe.
            _ = posix.read(signal_pipe[0], &buf) catch {};
            // Propagate new terminal size to PTY.
            const size = try terminal.getSize();
            try pty.setSize(size);
        }

        // Handle PTY output → terminal.
        if (fds[1].revents & posix.POLL.IN != 0) {
            const n = pty.read(&buf) catch break; // child exited
            if (n == 0) break;
            try terminal.writeAll(buf[0..n]);
        }

        // Handle PTY hangup (child exited).
        if (fds[1].revents & posix.POLL.HUP != 0) {
            // Read remaining output before exiting.
            while (true) {
                const n = pty.read(&buf) catch break;
                if (n == 0) break;
                try terminal.writeAll(buf[0..n]);
            }
            break;
        }

        // Handle terminal input → PTY.
        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = terminal.readInput(&buf) catch continue;
            for (buf[0..n]) |byte| {
                switch (handler.feed(byte)) {
                    .forward => |b| {
                        _ = try pty.writeInput(&.{b});
                    },
                    .quit => return,
                    .focus_up, .focus_down, .focus_left, .focus_right, .none => {},
                }
            }
        }
    }
}

/// Open a URL using the system default handler.
/// Runs asynchronously so it doesn't block the event loop.
/// Open a URL using the system default handler.
fn openUrl(url: []const u8) void {
    const builtin = @import("builtin");
    const opener: []const u8 = if (builtin.os.tag == .macos) "open" else "xdg-open";
    var child = std.process.Child.init(&.{ opener, url }, std.heap.page_allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return;
    _ = child.wait() catch {};
}

const CursorShape = enum {
    default,
    ew_resize,
    ns_resize,
    grab,
};

fn setCursorShape(terminal: *const Terminal.Terminal, shape: CursorShape, current: *CursorShape) void {
    if (shape == current.*) return;
    // OSC 22 with ST terminator (\x1b\\) for wider terminal compatibility.
    // Using ew-resize/ns-resize from the kitty pointer-shapes standard
    // (col-resize/row-resize are not in the standard 30 CSS names).
    const seq = switch (shape) {
        .default => "\x1b]22;default\x1b\\",
        .ew_resize => "\x1b]22;ew-resize\x1b\\",
        .ns_resize => "\x1b]22;ns-resize\x1b\\",
        .grab => "\x1b]22;grab\x1b\\",
    };
    terminal.writeAll(seq) catch {};
    current.* = shape;
}

const JunctionBorders = struct {
    vertical: ?Layout.BorderInfo = null,
    horizontal: ?Layout.BorderInfo = null,
};

/// At a junction (T or cross), scan nearby cells to find both the vertical
/// and horizontal borders. borderAt's straight-line scan fails at junctions
/// because the perpendicular gap blocks it, so we scan along each axis
/// separately and filter by orientation.
fn findJunctionBorders(rects: []const Layout.Rect, row: u16, col: u16) JunctionBorders {
    var result = JunctionBorders{};
    var d: u16 = 1;
    while (d <= 4) : (d += 1) {
        // Scan up/down to find a vertical border segment
        if (result.vertical == null) {
            if (row >= d) {
                if (Layout.borderAt(rects, row - d, col)) |b| {
                    if (b.is_vertical) result.vertical = b;
                }
            }
            if (result.vertical == null) {
                if (Layout.borderAt(rects, row + d, col)) |b| {
                    if (b.is_vertical) result.vertical = b;
                }
            }
        }
        // Scan left/right to find a horizontal border segment
        if (result.horizontal == null) {
            if (col >= d) {
                if (Layout.borderAt(rects, row, col - d)) |b| {
                    if (!b.is_vertical) result.horizontal = b;
                }
            }
            if (result.horizontal == null) {
                if (Layout.borderAt(rects, row, col + d)) |b| {
                    if (!b.is_vertical) result.horizontal = b;
                }
            }
        }
        if (result.vertical != null and result.horizontal != null) break;
    }
    return result;
}

/// Returns true if the position is a junction point (not inside any pane
/// and not on a simple border).
fn isJunction(rects: []const Layout.Rect, row: u16, col: u16) bool {
    return Layout.borderAt(rects, row, col) == null and
        Layout.paneAt(rects, row, col) == null;
}

const SelectionAnchor = struct {
    pane: usize,
    unified_row: i64,
    col: u16,
};

const Selection = struct {
    pane: usize,
    start_row: i64,
    start_col: u16,
    end_row: i64,
    end_col: u16,

    fn normalized(self: Selection) Selection {
        if (self.start_row > self.end_row or
            (self.start_row == self.end_row and self.start_col > self.end_col))
        {
            return .{
                .pane = self.pane,
                .start_row = self.end_row,
                .start_col = self.end_col,
                .end_row = self.start_row,
                .end_col = self.start_col,
            };
        }
        return self;
    }

    fn contains(self: Selection, unified_row: i64, col: u16) bool {
        if (unified_row < self.start_row or unified_row > self.end_row) return false;
        if (self.start_row == self.end_row) {
            return col >= self.start_col and col <= self.end_col;
        }
        if (unified_row == self.start_row) return col >= self.start_col;
        if (unified_row == self.end_row) return col <= self.end_col;
        return true;
    }
};

const max_panes = 32;

pub fn runMultiPane(
    allocator: std.mem.Allocator,
    terminal: *Terminal.Terminal,
    panes: []Pane,
    renderer: *Renderer,
    rects: []Layout.Rect,
    config_pane: Config.Pane,
    active_pane: *usize,
    prefix_key: u8,
    pane_gap: u16,
    bindings: []const input.Binding,
) !void {
    try installSignalHandler();
    defer {
        posix.close(signal_pipe[0]);
        posix.close(signal_pipe[1]);
    }

    // Enable mouse tracking (SGR mode for extended coordinates)
    try terminal.enableMouseTracking();
    var cursor_shape: CursorShape = .default;
    defer {
        setCursorShape(terminal, .default, &cursor_shape);
        terminal.disableMouseTracking() catch {};
    }

    var handler = input.InputHandler.initWithBindings(prefix_key, bindings);
    var mouse_parser = MouseParser{};
    var drag_state: ?DragState = null;
    var selection_anchor: ?SelectionAnchor = null;
    var selection: ?Selection = null;
    var buf: [4096]u8 = undefined;

    // Initial render — clear screen once to start with a clean slate.
    try terminal.writeAll("\x1b[2J");
    recomputeBorders(renderer, panes, rects, active_pane.*, handler.state == .command);
    try renderAll(allocator, terminal, renderer, panes, rects, active_pane.*, selection);

    while (true) {
        // Build pollfd array: [terminal, pane0_pty, pane1_pty, ..., signal_pipe]
        // Exited panes get fd=-1 so poll() ignores them.
        var fds: [max_panes + 2]posix.pollfd = undefined;
        fds[0] = .{ .fd = terminal.fd, .events = posix.POLL.IN, .revents = 0 };
        for (panes, 0..) |*pane, i| {
            fds[i + 1] = .{
                .fd = if (pane.isAlive()) pane.pty.master_fd else -1,
                .events = posix.POLL.IN,
                .revents = 0,
            };
        }
        const sig_idx = panes.len + 1;
        fds[sig_idx] = .{ .fd = signal_pipe[0], .events = posix.POLL.IN, .revents = 0 };

        _ = posix.poll(fds[0 .. sig_idx + 1], -1) catch |err| switch (err) {
            error.NetworkSubsystemFailed => return err,
            else => continue,
        };

        var needs_render = false;

        // Handle signal pipe (SIGWINCH)
        if (fds[sig_idx].revents & posix.POLL.IN != 0) {
            _ = posix.read(signal_pipe[0], &buf) catch {};
            const size = try terminal.getSize();

            // Recompute layout
            const area = Layout.Rect{ .col = 1, .row = 1, .width = size.cols -| 2, .height = size.rows -| 2 };
            const new_rects = try Layout.compute(allocator, config_pane, area, pane_gap);
            defer allocator.free(new_rects);

            // Resize panes and update rects
            for (panes, 0..) |*pane, i| {
                if (i < new_rects.len) {
                    rects[i] = new_rects[i];
                    if (pane.isAlive()) {
                        try pane.resize(new_rects[i]);
                    }
                }
            }

            // Resize renderer
            renderer.deinit();
            renderer.* = try Renderer.init(allocator, size.cols, size.rows);
            recomputeBorders(renderer, panes, rects, active_pane.*, handler.state == .command);
            // Clear screen on resize to remove stale content from the old layout.
            try terminal.writeAll("\x1b[2J");
            needs_render = true;
        }

        // Handle PTY output for alive panes.
        // Drain all available data before rendering so the cursor
        // and screen state reflect the child's final output, not an
        // intermediate position (e.g. after drawing the status bar
        // but before repositioning the cursor to the prompt).
        for (panes, 0..) |*pane, i| {
            if (!pane.isAlive()) continue;
            const fd_idx = i + 1;
            if (fds[fd_idx].revents & posix.POLL.IN != 0) {
                while (true) {
                    const n = pane.pty.read(&buf) catch {
                        handlePaneExit(pane);
                        break;
                    };
                    if (n == 0) {
                        handlePaneExit(pane);
                        break;
                    }
                    pane.feedOutput(buf[0..n]);
                    // Buffer not full — no more data waiting right now.
                    if (n < buf.len) break;
                }
                needs_render = true;
            }
            if (fds[fd_idx].revents & posix.POLL.HUP != 0) {
                // Drain remaining output
                while (true) {
                    const n = pane.pty.read(&buf) catch break;
                    if (n == 0) break;
                    pane.feedOutput(buf[0..n]);
                }
                handlePaneExit(pane);
                needs_render = true;
            }
        }

        // If all panes have exited, render final state and quit.
        var all_exited = true;
        for (panes) |*pane| {
            if (pane.isAlive()) {
                all_exited = false;
                break;
            }
        }
        // Handle terminal input → active pane
        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = terminal.readInput(&buf) catch continue;
            if (active_pane.* < panes.len) {
                for (buf[0..n]) |byte| {
                    // Mouse parser intercepts SGR mouse sequences before
                    // they reach the keyboard input handler.
                    switch (mouse_parser.feed(byte)) {
                        .passthrough => |b| {
                            processKeyByte(b, &handler, panes, rects, active_pane, renderer, &needs_render) catch |err| switch (err) {
                                error.Quit => {
                                    gracefulShutdown(panes);
                                    return;
                                },
                                else => return err,
                            };
                        },
                        .consumed => {},
                        .event => |ev| {
                            handleMouseEvent(ev, panes, rects, active_pane, renderer, &handler, &drag_state, &selection_anchor, &selection, &needs_render, pane_gap, terminal, &cursor_shape);
                        },
                        .escape_passthrough => |b| {
                            processKeyByte(0x1B, &handler, panes, rects, active_pane, renderer, &needs_render) catch |err| switch (err) {
                                error.Quit => {
                                    gracefulShutdown(panes);
                                    return;
                                },
                                else => return err,
                            };
                            processKeyByte(b, &handler, panes, rects, active_pane, renderer, &needs_render) catch |err| switch (err) {
                                error.Quit => {
                                    gracefulShutdown(panes);
                                    return;
                                },
                                else => return err,
                            };
                        },
                        .csi_passthrough => |b| {
                            processKeyByte(0x1B, &handler, panes, rects, active_pane, renderer, &needs_render) catch |err| switch (err) {
                                error.Quit => {
                                    gracefulShutdown(panes);
                                    return;
                                },
                                else => return err,
                            };
                            processKeyByte('[', &handler, panes, rects, active_pane, renderer, &needs_render) catch |err| switch (err) {
                                error.Quit => {
                                    gracefulShutdown(panes);
                                    return;
                                },
                                else => return err,
                            };
                            processKeyByte(b, &handler, panes, rects, active_pane, renderer, &needs_render) catch |err| switch (err) {
                                error.Quit => {
                                    gracefulShutdown(panes);
                                    return;
                                },
                                else => return err,
                            };
                        },
                    }
                }
            }
        }

        // Flush any bytes the mouse parser consumed but couldn't complete into
        // a mouse sequence (e.g. a single ESC key press).
        flushMouseParser(&mouse_parser, &handler, panes, rects, active_pane, renderer, &needs_render);

        if (needs_render) {
            try renderAll(allocator, terminal, renderer, panes, rects, active_pane.*, selection);
        }

        // All panes have exited — clear screen, show message, wait for key.
        if (all_exited) {
            try terminal.writeAll("\x1b[2J\x1b[H"); // Clear screen and move cursor to home.
            try terminal.writeAll("All panes exited. Press any key to exit zyouz.\r\n");
            var key: [4]u8 = undefined;
            _ = terminal.readInput(&key) catch {};
            return;
        }
    }
}

/// If the mouse parser consumed ESC (or ESC [) as a mouse sequence prefix but
/// no bytes followed, replay the bytes so they reach the input handler.
fn flushMouseParser(
    mouse_parser: *MouseParser,
    handler: *input.InputHandler,
    panes: []Pane,
    rects: []const Layout.Rect,
    active_pane: *usize,
    renderer: *Renderer,
    needs_render: *bool,
) void {
    // Check to see if bytes were consumed without emitting.
    switch (mouse_parser.state) {
        .esc => {
            mouse_parser.state = .ground;
            processKeyByte(0x1B, handler, panes, rects, active_pane, renderer, needs_render) catch |err| switch (err) {
                error.Quit => {
                    gracefulShutdown(panes);
                    return;
                },
                else => {},
            };
        },
        .csi => {
            mouse_parser.state = .ground;
            processKeyByte(0x1B, handler, panes, rects, active_pane, renderer, needs_render) catch |err| switch (err) {
                error.Quit => {
                    gracefulShutdown(panes);
                    return;
                },
                else => {},
            };
            processKeyByte('[', handler, panes, rects, active_pane, renderer, needs_render) catch |err| switch (err) {
                error.Quit => {
                    gracefulShutdown(panes);
                    return;
                },
                else => {},
            };
        },
        .params => {
            // Incomplete so just reset.
            mouse_parser.state = .ground;
            mouse_parser.param_len = 0;
        },
        .ground => {},
    }
}

fn processKeyByte(
    byte: u8,
    handler: *input.InputHandler,
    panes: []Pane,
    rects: []const Layout.Rect,
    active_pane: *usize,
    renderer: *Renderer,
    needs_render: *bool,
) !void {
    const prev_state = handler.state;
    switch (handler.feed(byte)) {
        .forward => |b| {
            if (active_pane.* < panes.len and panes[active_pane.*].isAlive()) {
                _ = try panes[active_pane.*].pty.writeInput(&.{b});
            }
        },
        .quit => return error.Quit,
        .focus_up => handleFocus(rects, active_pane, renderer, handler, needs_render, .up, panes),
        .focus_down => handleFocus(rects, active_pane, renderer, handler, needs_render, .down, panes),
        .focus_left => handleFocus(rects, active_pane, renderer, handler, needs_render, .left, panes),
        .focus_right => handleFocus(rects, active_pane, renderer, handler, needs_render, .right, panes),
        .none => {},
    }
    if (handler.state != prev_state and
        (handler.state == .command or prev_state == .command))
    {
        recomputeBorders(renderer, panes, rects, active_pane.*, handler.state == .command);
        needs_render.* = true;
    }
}

const DragState = struct {
    border: Layout.BorderInfo,
    /// Second border at a junction point. On the first drag event,
    /// the direction of mouse movement determines which border to use,
    /// then this field is cleared to null.
    alt_border: ?Layout.BorderInfo = null,
    last_col: u16,
    last_row: u16,
};

const min_pane_size: u16 = 2;

/// Check for a resizable border at the exact position or on the pane edge.
/// When the click lands inside a pane near its edge, uses findNeighbor to
/// locate the adjacent pane. This avoids the junction problem where
/// borderAt fails at the intersection of vertical and horizontal dividers
/// (e.g., in a layout with a left pane and a vertically-split right pane,
/// borderAt cannot find panes across the junction row).
fn findBorderNear(rects: []const Layout.Rect, row: u16, col: u16) ?Layout.BorderInfo {
    // Direct hit on a border cell — works for most positions except junctions.
    if (Layout.borderAt(rects, row, col)) |b| return b;

    // Click is inside a pane — check if we're on the pane edge.
    const pane_idx = Layout.paneAt(rects, row, col) orelse {
        // Junction point: not inside any pane and borderAt failed.
        // At T-junctions and cross-intersections, borderAt's straight-line
        // scan can't find panes because the perpendicular gap blocks it.
        // Scan nearby cells to find a valid border.
        var d: u16 = 1;
        while (d <= 4) : (d += 1) {
            if (row >= d) {
                if (Layout.borderAt(rects, row - d, col)) |b| return b;
            }
            if (Layout.borderAt(rects, row + d, col)) |b| return b;
            if (col >= d) {
                if (Layout.borderAt(rects, row, col - d)) |b| return b;
            }
            if (Layout.borderAt(rects, row, col + d)) |b| return b;
        }
        return null;
    };
    const r = rects[pane_idx];

    // Right edge of pane (last content column)
    if (col + 1 >= r.col + r.width) {
        if (Layout.findNeighbor(rects, pane_idx, .right)) |neighbor| {
            return .{ .pane_before = pane_idx, .pane_after = neighbor, .is_vertical = true };
        }
    }
    // Left edge of pane (first content column)
    if (col == r.col) {
        if (Layout.findNeighbor(rects, pane_idx, .left)) |neighbor| {
            return .{ .pane_before = neighbor, .pane_after = pane_idx, .is_vertical = true };
        }
    }
    // Bottom edge of pane (last content row)
    if (row + 1 >= r.row + r.height) {
        if (Layout.findNeighbor(rects, pane_idx, .down)) |neighbor| {
            return .{ .pane_before = pane_idx, .pane_after = neighbor, .is_vertical = false };
        }
    }
    // Top edge of pane (first content row)
    if (row == r.row) {
        if (Layout.findNeighbor(rects, pane_idx, .up)) |neighbor| {
            return .{ .pane_before = neighbor, .pane_after = pane_idx, .is_vertical = false };
        }
    }
    return null;
}

fn unifiedRowFromMouse(panes: []const Pane, rects: []const Layout.Rect, pane_idx: usize, ev_row: u16) i64 {
    const screen = &panes[pane_idx].screen;
    const local_row: i64 = @as(i64, ev_row) - @as(i64, rects[pane_idx].row);
    const sb_count: i64 = @intCast(screen.scrollbackLen());
    const scroll_offset: i64 = @intCast(panes[pane_idx].scroll_offset);
    return sb_count - scroll_offset + local_row;
}

fn copySelectionToClipboard(terminal: *const Terminal.Terminal, panes: []const Pane, sel: Selection) void {
    const Screen = @import("Screen.zig");
    const n = sel.normalized();
    const screen: *const Screen = &panes[n.pane].screen;
    const sb_count: i64 = @intCast(screen.scrollbackLen());

    // Build selected text into a buffer
    var text_buf: [16384]u8 = undefined;
    var text_pos: usize = 0;

    var row = n.start_row;
    while (row <= n.end_row) : (row += 1) {
        const start_c: u16 = if (row == n.start_row) n.start_col else 0;
        const end_c: u16 = if (row == n.end_row) n.end_col else screen.width -| 1;

        var line_buf: [1024]u8 = undefined;
        const line_text = if (row < sb_count) blk: {
            // Scrollback line
            const sb_idx: usize = @intCast(row);
            if (screen.scrollbackLine(sb_idx)) |line| {
                var lpos: usize = 0;
                var c = start_c;
                while (c <= end_c) : (c += 1) {
                    if (c >= line.len) break;
                    const cell = &line[c];
                    if (cell.char == 0) continue;
                    var utf8: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cell.char, &utf8) catch continue;
                    if (lpos + len > line_buf.len) break;
                    @memcpy(line_buf[lpos..][0..len], utf8[0..len]);
                    lpos += len;
                }
                while (lpos > 0 and line_buf[lpos - 1] == ' ') lpos -= 1;
                break :blk line_buf[0..lpos];
            }
            break :blk @as([]const u8, "");
        } else blk: {
            // Live screen line
            const screen_row: u16 = @intCast(row - sb_count);
            break :blk screen.extractLineText(screen_row, start_c, end_c, &line_buf);
        };

        if (text_pos + line_text.len + 1 > text_buf.len) break;
        @memcpy(text_buf[text_pos..][0..line_text.len], line_text);
        text_pos += line_text.len;
        if (row < n.end_row) {
            text_buf[text_pos] = '\n';
            text_pos += 1;
        }
    }

    if (text_pos == 0) return;

    // Base64 encode and send via OSC 52
    const text = text_buf[0..text_pos];
    var b64_buf: [24000]u8 = undefined;
    const b64_len = std.base64.standard.Encoder.calcSize(text.len);
    if (b64_len > b64_buf.len) return;
    const b64 = std.base64.standard.Encoder.encode(b64_buf[0..b64_len], text);

    // OSC 52: \x1b]52;c;<base64>\x07
    terminal.writeAll("\x1b]52;c;") catch return;
    terminal.writeAll(b64) catch return;
    terminal.writeAll("\x07") catch return;
}

fn handleMouseEvent(
    ev: MouseParser.MouseEvent,
    panes: []Pane,
    rects: []Layout.Rect,
    active_pane: *usize,
    renderer: *Renderer,
    handler: *const input.InputHandler,
    drag_state: *?DragState,
    selection_anchor: *?SelectionAnchor,
    selection: *?Selection,
    needs_render: *bool,
    pane_gap: u16,
    terminal: *const Terminal.Terminal,
    cursor_shape: *CursorShape,
) void {
    switch (ev.kind) {
        .motion => {
            if (isJunction(rects, ev.row, ev.col)) {
                const jb = findJunctionBorders(rects, ev.row, ev.col);
                if (jb.vertical != null or jb.horizontal != null) {
                    setCursorShape(terminal, .grab, cursor_shape);
                } else {
                    setCursorShape(terminal, .default, cursor_shape);
                }
            } else if (findBorderNear(rects, ev.row, ev.col)) |border| {
                const shape: CursorShape = if (border.is_vertical) .ew_resize else .ns_resize;
                setCursorShape(terminal, shape, cursor_shape);
            } else {
                setCursorShape(terminal, .default, cursor_shape);
            }
        },
        .press => {
            if (ev.button == .scroll_up or ev.button == .scroll_down or
                ev.button == .scroll_left or ev.button == .scroll_right)
            {
                if (Layout.paneAt(rects, ev.row, ev.col)) |target_pane| {
                    if (panes[target_pane].mouse_mode == .passthrough) {
                        var sgr_buf: [32]u8 = undefined;
                        const sgr = ev.formatSgr(&sgr_buf, rects[target_pane].col, rects[target_pane].row);
                        if (sgr.len > 0) {
                            _ = panes[target_pane].pty.writeInput(sgr) catch {};
                        }
                    } else {
                        // Horizontal scroll: no-op for non-passthrough
                        // (content wraps at screen width)
                        if (ev.button == .scroll_up) {
                            panes[target_pane].scrollViewUp(3);
                        } else if (ev.button == .scroll_down) {
                            panes[target_pane].scrollViewDown(3);
                        }
                        needs_render.* = true;
                    }
                }
                return;
            }
            if (ev.button == .left and ev.modifiers.ctrl) {
                // Ctrl+click: open hyperlink if the cell has one.
                // Ghostty doesn't handle OSC 8 link clicks when mouse
                // tracking is enabled, so zyouz handles it directly.
                if (Layout.paneAt(rects, ev.row, ev.col)) |target_pane| {
                    const local_row = ev.row -| rects[target_pane].row;
                    const local_col = ev.col -| rects[target_pane].col;
                    const cell = panes[target_pane].screen.cellAt(local_row, local_col);
                    if (panes[target_pane].screen.hyperlinkUrl(cell.hyperlink)) |url| {
                        openUrl(url);
                        return;
                    }
                }
            }
            if (ev.button == .left) {
                // Check if clicking on a junction (T or cross intersection)
                if (isJunction(rects, ev.row, ev.col)) {
                    const jb = findJunctionBorders(rects, ev.row, ev.col);
                    if (jb.vertical != null or jb.horizontal != null) {
                        drag_state.* = .{
                            .border = jb.vertical orelse jb.horizontal.?,
                            .alt_border = if (jb.vertical != null) jb.horizontal else null,
                            .last_col = ev.col,
                            .last_row = ev.row,
                        };
                        setCursorShape(terminal, .grab, cursor_shape);
                        return;
                    }
                }
                // Check if clicking on or near a border to start drag
                if (findBorderNear(rects, ev.row, ev.col)) |border| {
                    drag_state.* = .{
                        .border = border,
                        .last_col = ev.col,
                        .last_row = ev.row,
                    };
                    const shape: CursorShape = if (border.is_vertical) .ew_resize else .ns_resize;
                    setCursorShape(terminal, shape, cursor_shape);
                    return;
                }
                // Record selection anchor for potential drag selection
                if (Layout.paneAt(rects, ev.row, ev.col)) |target_pane| {
                    if (panes[target_pane].mouse_mode == .passthrough) {
                        var sgr_buf: [32]u8 = undefined;
                        const sgr = ev.formatSgr(&sgr_buf, rects[target_pane].col, rects[target_pane].row);
                        if (sgr.len > 0) {
                            _ = panes[target_pane].pty.writeInput(sgr) catch {};
                        }
                    } else {
                        const local_col = ev.col -| rects[target_pane].col;
                        selection_anchor.* = .{
                            .pane = target_pane,
                            .unified_row = unifiedRowFromMouse(panes, rects, target_pane, ev.row),
                            .col = local_col,
                        };
                        selection.* = null;
                    }
                    if (target_pane != active_pane.*) {
                        active_pane.* = target_pane;
                        recomputeBorders(renderer, panes, rects, active_pane.*, handler.state == .command);
                        needs_render.* = true;
                    }
                }
            }
        },
        .drag => {
            if (ev.button == .left) {
                if (drag_state.*) |*ds| {
                    // At a junction, resolve which border to drag based on
                    // the direction of the first mouse movement.
                    if (ds.alt_border != null) {
                        const dx: u32 = @abs(@as(i32, ev.col) - @as(i32, ds.last_col));
                        const dy: u32 = @abs(@as(i32, ev.row) - @as(i32, ds.last_row));
                        if (dx == 0 and dy == 0) return; // wait for movement
                        if (dy > dx) {
                            // Vertical mouse movement → drag the horizontal border
                            ds.border = ds.alt_border.?;
                        }
                        ds.alt_border = null;
                        const shape: CursorShape = if (ds.border.is_vertical) .ew_resize else .ns_resize;
                        setCursorShape(terminal, shape, cursor_shape);
                    }
                    applyDrag(ds, ev, panes, rects, renderer, active_pane, handler, needs_render, pane_gap);
                } else if (selection_anchor.*) |anchor| {
                    // Text selection drag
                    if (Layout.paneAt(rects, ev.row, ev.col)) |target_pane| {
                        if (target_pane == anchor.pane) {
                            const local_col = ev.col -| rects[target_pane].col;
                            const unified = unifiedRowFromMouse(panes, rects, target_pane, ev.row);
                            selection.* = .{
                                .pane = anchor.pane,
                                .start_row = anchor.unified_row,
                                .start_col = anchor.col,
                                .end_row = unified,
                                .end_col = local_col,
                            };
                            needs_render.* = true;

                            // Auto-scroll when dragging past pane edges
                            const rect = rects[target_pane];
                            if (ev.row <= rect.row and panes[target_pane].scroll_offset < panes[target_pane].screen.scrollbackLen()) {
                                panes[target_pane].scrollViewUp(1);
                                selection.*.?.end_row -= 1;
                            } else if (ev.row >= rect.row + rect.height -| 1 and panes[target_pane].scroll_offset > 0) {
                                panes[target_pane].scrollViewDown(1);
                                selection.*.?.end_row += 1;
                            }
                        }
                    }
                } else {
                    // Drag on a passthrough pane → forward
                    if (Layout.paneAt(rects, ev.row, ev.col)) |target_pane| {
                        if (panes[target_pane].mouse_mode == .passthrough) {
                            var sgr_buf: [32]u8 = undefined;
                            const sgr = ev.formatSgr(&sgr_buf, rects[target_pane].col, rects[target_pane].row);
                            if (sgr.len > 0) {
                                _ = panes[target_pane].pty.writeInput(sgr) catch {};
                            }
                        }
                    }
                }
            }
        },
        .release => {
            if (selection.*) |sel| {
                copySelectionToClipboard(terminal, panes, sel);
                selection.* = null;
                selection_anchor.* = null;
                needs_render.* = true;
            } else if (selection_anchor.*) |anchor| {
                // Click without drag — handle hyperlink open or focus
                selection_anchor.* = null;
                if (panes[anchor.pane].mouse_mode != .passthrough and anchor.pane == active_pane.*) {
                    const local_row = ev.row -| rects[anchor.pane].row;
                    const local_col = ev.col -| rects[anchor.pane].col;
                    const cell = panes[anchor.pane].screen.cellAt(local_row, local_col);
                    if (panes[anchor.pane].screen.hyperlinkUrl(cell.hyperlink)) |url| {
                        openUrl(url);
                    }
                } else if (anchor.pane != active_pane.*) {
                    active_pane.* = anchor.pane;
                    recomputeBorders(renderer, panes, rects, active_pane.*, handler.state == .command);
                    needs_render.* = true;
                }
            }
            drag_state.* = null;
            setCursorShape(terminal, .default, cursor_shape);
            // Forward release to passthrough panes
            if (Layout.paneAt(rects, ev.row, ev.col)) |target_pane| {
                if (panes[target_pane].mouse_mode == .passthrough) {
                    var sgr_buf: [32]u8 = undefined;
                    const sgr = ev.formatSgr(&sgr_buf, rects[target_pane].col, rects[target_pane].row);
                    if (sgr.len > 0) {
                        _ = panes[target_pane].pty.writeInput(sgr) catch {};
                    }
                }
            }
        },
    }
}

fn applyDrag(
    ds: *DragState,
    ev: MouseParser.MouseEvent,
    panes: []Pane,
    rects: []Layout.Rect,
    renderer: *Renderer,
    active_pane: *const usize,
    handler: *const input.InputHandler,
    needs_render: *bool,
    pane_gap: u16,
) void {
    // Must match Layout.computeSplit divider_width formula.
    const divider_width: u16 = 1 + pane_gap;

    if (ds.border.is_vertical) {
        const delta: i32 = @as(i32, ev.col) - @as(i32, ds.last_col);
        if (delta == 0) return;

        // Current border column: right edge of the "before" reference pane.
        const border_col: u16 = rects[ds.border.pane_before].col + rects[ds.border.pane_before].width;
        // Pane after the divider starts at border_col + divider_width.
        const after_col: u16 = border_col + divider_width;

        // Check all panes sharing this border can accommodate the resize.
        for (rects) |r| {
            if (r.col + r.width == border_col) {
                if (@as(i32, r.width) + delta < min_pane_size) return;
            } else if (r.col == after_col) {
                if (@as(i32, r.width) - delta < min_pane_size) return;
            }
        }

        // Apply to ALL panes sharing the border.
        for (rects, 0..) |*r, i| {
            if (r.col + r.width == border_col) {
                r.width = @intCast(@as(i32, r.width) + delta);
                panes[i].resize(r.*) catch {};
            } else if (r.col == after_col) {
                r.col = @intCast(@as(i32, r.col) + delta);
                r.width = @intCast(@as(i32, r.width) - delta);
                panes[i].resize(r.*) catch {};
            }
        }
    } else {
        const delta: i32 = @as(i32, ev.row) - @as(i32, ds.last_row);
        if (delta == 0) return;

        // Current border row: bottom edge of the "before" reference pane.
        const border_row: u16 = rects[ds.border.pane_before].row + rects[ds.border.pane_before].height;
        // Pane after the divider starts at border_row + divider_width.
        const after_row: u16 = border_row + divider_width;

        for (rects) |r| {
            if (r.row + r.height == border_row) {
                if (@as(i32, r.height) + delta < min_pane_size) return;
            } else if (r.row == after_row) {
                if (@as(i32, r.height) - delta < min_pane_size) return;
            }
        }

        for (rects, 0..) |*r, i| {
            if (r.row + r.height == border_row) {
                r.height = @intCast(@as(i32, r.height) + delta);
                panes[i].resize(r.*) catch {};
            } else if (r.row == after_row) {
                r.row = @intCast(@as(i32, r.row) + delta);
                r.height = @intCast(@as(i32, r.height) - delta);
                panes[i].resize(r.*) catch {};
            }
        }
    }

    ds.last_col = ev.col;
    ds.last_row = ev.row;

    recomputeBorders(renderer, panes, rects, active_pane.*, handler.state == .command);
    needs_render.* = true;
}

fn handleFocus(
    rects: []const Layout.Rect,
    active_pane: *usize,
    renderer: *Renderer,
    handler: *const input.InputHandler,
    needs_render: *bool,
    dir: Layout.Direction,
    panes: []const Pane,
) void {
    if (Layout.findNeighbor(rects, active_pane.*, dir)) |neighbor| {
        active_pane.* = neighbor;
        recomputeBorders(renderer, panes, rects, active_pane.*, handler.state == .command);
        needs_render.* = true;
    }
}

const shutdown_timeout_ns = 500 * std.time.ns_per_ms;

fn gracefulShutdown(panes: []Pane) void {
    // Phase 1: Send SIGHUP + SIGTERM to all alive panes.
    // Interactive shells respond to SIGHUP faster than SIGTERM.
    for (panes) |*pane| {
        if (pane.isAlive()) {
            pane.pty.sendSignal(posix.SIG.HUP) catch {};
            pane.pty.sendSignal(posix.SIG.TERM) catch {};
        }
    }

    // Phase 2: Poll for exit with timeout
    const poll_interval: u64 = 5 * std.time.ns_per_ms;
    var elapsed: u64 = 0;
    while (elapsed < shutdown_timeout_ns) {
        var all_exited = true;
        for (panes) |*pane| {
            if (pane.isAlive()) {
                if (pane.pty.checkExited()) |code| {
                    pane.markExited(code);
                } else {
                    all_exited = false;
                }
            }
        }
        if (all_exited) return;
        std.Thread.sleep(poll_interval);
        elapsed += poll_interval;
    }

    // Phase 3: SIGKILL remaining alive panes
    for (panes) |*pane| {
        if (pane.isAlive()) {
            pane.pty.sendSignal(posix.SIG.KILL) catch {};
        }
    }

    // Brief wait for SIGKILL to take effect, then reap.
    std.Thread.sleep(1 * std.time.ns_per_ms);
    for (panes) |*pane| {
        if (pane.isAlive()) {
            if (pane.pty.checkExited()) |code| {
                pane.markExited(code);
            }
        }
    }
}

fn handlePaneExit(pane: *Pane) void {
    const exit_code = pane.pty.checkExited() orelse 255;
    pane.markExited(exit_code);

    if (Pane.shouldRestart(pane.restart, exit_code)) {
        pane.respawn() catch {};
    }
}

fn buildPaneStates(panes: []const Pane) [max_panes]Pane.ProcessState {
    var states: [max_panes]Pane.ProcessState = undefined;
    for (panes, 0..) |*pane, i| {
        states[i] = pane.process_state;
    }
    return states;
}

fn buildPaneNames(panes: []const Pane) [max_panes][]const u8 {
    var names: [max_panes][]const u8 = undefined;
    for (panes, 0..) |*pane, i| {
        names[i] = pane.name;
    }
    return names;
}

fn recomputeBorders(renderer: *Renderer, panes: []const Pane, rects: []const Layout.Rect, active_pane: usize, command_mode: bool) void {
    const states = buildPaneStates(panes);
    renderer.computeBordersWithState(rects, active_pane, command_mode, states[0..panes.len]);
    const names = buildPaneNames(panes);
    renderer.renderPaneNames(rects, names[0..panes.len]);
}

fn renderAll(
    allocator: std.mem.Allocator,
    terminal: *Terminal.Terminal,
    renderer: *const Renderer,
    panes: []Pane,
    rects: []const Layout.Rect,
    active_pane: usize,
    sel: ?Selection,
) !void {
    const Screen = @import("Screen.zig");
    // Build screen pointer and scroll offset arrays
    var screens: [max_panes]*const Screen = undefined;
    var scroll_offsets: [max_panes]usize = undefined;
    for (panes, 0..) |*pane, i| {
        screens[i] = &pane.screen;
        scroll_offsets[i] = pane.scroll_offset;
    }

    // Build selection ranges per pane
    var pane_selections: [max_panes]?Renderer.SelectionRange = .{null} ** max_panes;
    if (sel) |s| {
        const n = s.normalized();
        pane_selections[s.pane] = .{
            .start_row = n.start_row,
            .start_col = n.start_col,
            .end_row = n.end_row,
            .end_col = n.end_col,
        };
    }

    // Dynamic buffer: typical frame is 50-200 KB for colorful content.
    var render_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer render_buf.deinit(allocator);
    const writer = render_buf.writer(allocator);

    try renderer.renderFrameWithScrollback(
        writer,
        screens[0..panes.len],
        rects,
        scroll_offsets[0..panes.len],
        active_pane,
        pane_selections[0..panes.len],
    );

    // Render exit status overlays for exited panes
    const states = buildPaneStates(panes);
    renderer.renderExitStatuses(writer, rects, states[0..panes.len]) catch {};

    try terminal.writeAll(render_buf.items);
}

test "Selection.contains single line" {
    const sel = Selection{
        .pane = 0,
        .start_row = 5,
        .start_col = 3,
        .end_row = 5,
        .end_col = 8,
    };
    const n = sel.normalized();
    try std.testing.expect(n.contains(5, 3));
    try std.testing.expect(n.contains(5, 5));
    try std.testing.expect(n.contains(5, 8));
    try std.testing.expect(!n.contains(5, 2));
    try std.testing.expect(!n.contains(5, 9));
    try std.testing.expect(!n.contains(4, 5));
}

test "Selection.contains multi line" {
    const sel = Selection{
        .pane = 0,
        .start_row = 10,
        .start_col = 5,
        .end_row = 12,
        .end_col = 3,
    };
    const n = sel.normalized();
    try std.testing.expect(n.contains(10, 5));
    try std.testing.expect(n.contains(10, 40));
    try std.testing.expect(!n.contains(10, 4));
    try std.testing.expect(n.contains(11, 0));
    try std.testing.expect(n.contains(11, 999));
    try std.testing.expect(n.contains(12, 0));
    try std.testing.expect(n.contains(12, 3));
    try std.testing.expect(!n.contains(12, 4));
}

test "Selection.normalized reverses when end before start" {
    const sel = Selection{
        .pane = 0,
        .start_row = 10,
        .start_col = 5,
        .end_row = 8,
        .end_col = 3,
    };
    const n = sel.normalized();
    try std.testing.expectEqual(@as(i64, 8), n.start_row);
    try std.testing.expectEqual(@as(u16, 3), n.start_col);
    try std.testing.expectEqual(@as(i64, 10), n.end_row);
    try std.testing.expectEqual(@as(u16, 5), n.end_col);
}

test "flushMouseParser unsticks ESC from mouse parser" {
    var parser = MouseParser{};
    _ = parser.feed(0x1B);
    try std.testing.expectEqual(MouseParser.State.esc, parser.state);

    var handler = input.InputHandler{};
    var empty_panes: [0]Pane = .{};
    var empty_rects: [0]Layout.Rect = .{};
    var active_pane: usize = 0;
    const alloc = std.testing.allocator;
    var renderer = Renderer{
        .width = 0,
        .height = 0,
        .border_grid = &.{},
        .border_cells = &.{},
        .border_colors = &.{},
        .pane_adjacency = &.{},
        .allocator = alloc,
    };
    var needs_render = false;

    flushMouseParser(&parser, &handler, &empty_panes, &empty_rects, &active_pane, &renderer, &needs_render);

    try std.testing.expectEqual(MouseParser.State.ground, parser.state);
    try std.testing.expectEqual(MouseParser.Result{ .passthrough = 'a' }, parser.feed('a'));
}

test "flushMouseParser is no-op when parser is already in ground state" {
    var parser = MouseParser{};
    try std.testing.expectEqual(MouseParser.State.ground, parser.state);

    var handler = input.InputHandler{};
    var empty_panes: [0]Pane = .{};
    var empty_rects: [0]Layout.Rect = .{};
    var active_pane: usize = 0;
    var renderer = Renderer{
        .width = 0,
        .height = 0,
        .border_grid = &.{},
        .border_cells = &.{},
        .border_colors = &.{},
        .pane_adjacency = &.{},
        .allocator = std.testing.allocator,
    };
    var needs_render = false;

    flushMouseParser(&parser, &handler, &empty_panes, &empty_rects, &active_pane, &renderer, &needs_render);

    try std.testing.expectEqual(MouseParser.State.ground, parser.state);
    try std.testing.expectEqual(MouseParser.Result{ .passthrough = 'a' }, parser.feed('a'));
}
