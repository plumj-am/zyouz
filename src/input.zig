const std = @import("std");

pub const Action = union(enum) {
    /// Forward this byte to the PTY.
    forward: u8,
    /// Clean shutdown requested (Ctrl+S → Ctrl+Q).
    quit,
    /// Switch focus directionally.
    focus_up,
    focus_down,
    focus_left,
    focus_right,
    /// Input consumed by state machine, no action needed.
    none,
};

/// Maps a key byte sequence (from human-readable name) to an action. Bindings
/// are only matched in command mode.
pub const Binding = struct {
    action: Action,
    /// Byte sequence that triggers the action.
    /// e.g. [0x11] for ctrl+q, [0x1B, '[', 'A'] for up arrow.
    sequence: []const u8,
};

pub const default_bindings = [_]Binding{
    .{ .action = .quit, .sequence = &[_]u8{0x11} }, // ctrl+q
    .{ .action = .focus_up, .sequence = &[_]u8{ 0x1B, '[', 'A' } },
    .{ .action = .focus_down, .sequence = &[_]u8{ 0x1B, '[', 'B' } },
    .{ .action = .focus_right, .sequence = &[_]u8{ 0x1B, '[', 'C' } },
    .{ .action = .focus_left, .sequence = &[_]u8{ 0x1B, '[', 'D' } },
};

/// Human-readable key name -> byte sequence.
/// Returns null if the key name is not recognised.
pub fn parseKey(allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    // ctrl-a through ctrl-z
    if (key.len == 6 and std.mem.eql(u8, key[0..5], "ctrl-")) {
        const ch = key[5];
        if (ch >= 'a' and ch <= 'z') {
            const buf = allocator.alloc(u8, 1) catch return null;
            buf[0] = ch - 'a' + 1;
            return buf[0..1];
        }
    }
    // Arrows.
    if (std.mem.eql(u8, key, "up")) {
        const buf = allocator.alloc(u8, 3) catch return null;
        buf[0] = 0x1B;
        buf[1] = '[';
        buf[2] = 'A';
        return buf;
    }
    if (std.mem.eql(u8, key, "down")) {
        const buf = allocator.alloc(u8, 3) catch return null;
        buf[0] = 0x1B;
        buf[1] = '[';
        buf[2] = 'B';
        return buf;
    }
    if (std.mem.eql(u8, key, "right")) {
        const buf = allocator.alloc(u8, 3) catch return null;
        buf[0] = 0x1B;
        buf[1] = '[';
        buf[2] = 'C';
        return buf;
    }
    if (std.mem.eql(u8, key, "left")) {
        const buf = allocator.alloc(u8, 3) catch return null;
        buf[0] = 0x1B;
        buf[1] = '[';
        buf[2] = 'D';
        return buf;
    }
    if (std.mem.eql(u8, key, "space")) {
        const buf = allocator.alloc(u8, 1) catch return null;
        buf[0] = ' ';
        return buf;
    }
    if (std.mem.eql(u8, key, "tab")) {
        const buf = allocator.alloc(u8, 1) catch return null;
        buf[0] = 0x09;
        return buf;
    }
    if (std.mem.eql(u8, key, "enter")) {
        const buf = allocator.alloc(u8, 1) catch return null;
        buf[0] = 0x0D;
        return buf;
    }
    if (std.mem.eql(u8, key, "backspace")) {
        const buf = allocator.alloc(u8, 1) catch return null;
        buf[0] = 0x7F;
        return buf;
    }
    if (std.mem.eql(u8, key, "escape")) {
        const buf = allocator.alloc(u8, 1) catch return null;
        buf[0] = 0x1B;
        return buf;
    }
    // All other characters e.g. "h", ".", ";" etc.
    if (key.len == 1) {
        const ch = key[0];
        // Only use printable ASCII (32-126) to avoid stop control chars being
        // seen as literal key names (we can use "tab", "enter", etc. from above
        // instead). <https://www.ascii-code.com>
        if (ch >= 32 and ch <= 126) {
            const buf = allocator.alloc(u8, 1) catch return null;
            buf[0] = ch;
            return buf;
        }
    }
    return null;
}

/// Human-readable action name -> Action.
pub fn parseAction(name: []const u8) ?Action {
    if (std.mem.eql(u8, name, "quit")) return .quit;
    if (std.mem.eql(u8, name, "focus_up")) return .focus_up;
    if (std.mem.eql(u8, name, "focus_down")) return .focus_down;
    if (std.mem.eql(u8, name, "focus_left")) return .focus_left;
    if (std.mem.eql(u8, name, "focus_right")) return .focus_right;
    return null;
}

pub const InputHandler = struct {
    state: State = .normal,
    prefix_key: u8 = default_prefix_key,
    bindings: []const Binding = &default_bindings,
    /// If true, focus actions exit command mode (default: stay in command mode).
    exit_on_focus: bool = false,

    const State = enum { normal, command, command_esc, command_csi };

    const default_prefix_key = 0x13; // ctrl+s

    pub fn initWithPrefix(prefix: u8) InputHandler {
        return .{ .prefix_key = prefix };
    }

    /// If bindings are empty, use defaults.
    pub fn initWithBindings(prefix: u8, bindings: []const Binding) InputHandler {
        if (bindings.len == 0) {
            return .{ .prefix_key = prefix };
        }
        return .{ .prefix_key = prefix, .bindings = bindings };
    }

    /// "ctrl-<letter>" string -> control character byte.
    /// Returns null if input is not valid ctrl-key string.
    pub fn parseCtrlKey(s: []const u8) ?u8 {
        if (s.len == 6 and std.mem.eql(u8, s[0..5], "ctrl-")) {
            const ch = s[5];
            if (ch >= 'a' and ch <= 'z') {
                return ch - 'a' + 1;
            }
        }
        return null;
    }

    /// Process a single byte of input. Returns the action to take.
    pub fn feed(self: *InputHandler, byte: u8) Action {
        switch (self.state) {
            .normal => {
                if (byte == self.prefix_key) {
                    self.state = .command;
                    return .none;
                }
                return .{ .forward = byte };
            },
            .command => {
                // Try matching single-byte bindings (e.g. ctrl+q)
                for (self.bindings) |b| {
                    if (b.sequence.len == 1 and b.sequence[0] == byte) {
                        return b.action;
                    }
                }
                if (byte == 0x1B) {
                    self.state = .command_esc;
                    return .none;
                }
                self.state = .normal;
                return .{ .forward = byte };
            },
            .command_esc => {
                if (byte == '[') {
                    self.state = .command_csi;
                    return .none;
                }
                // Not a CSI sequence — exit command mode
                self.state = .normal;
                return .{ .forward = byte };
            },
            .command_csi => {
                // Try matching 3-byte CSI bindings (ESC [ <byte>)
                for (self.bindings) |b| {
                    if (b.sequence.len == 3 and
                        b.sequence[0] == 0x1B and
                        b.sequence[1] == '[' and
                        b.sequence[2] == byte)
                    {
                        self.state = if (self.exit_on_focus) .normal else .command;
                        return b.action;
                    }
                }
                self.state = .normal;
                return .none;
            },
        }
    }
};

test "normal mode: regular byte is forwarded" {
    var handler = InputHandler{};
    const action = handler.feed('a');
    try std.testing.expectEqual(Action{ .forward = 'a' }, action);
}

test "normal mode: Ctrl+S enters command mode" {
    var handler = InputHandler{};
    const action = handler.feed(0x13); // Ctrl+S
    try std.testing.expectEqual(Action.none, action);
    try std.testing.expectEqual(InputHandler.State.command, handler.state);
}

test "command mode: Ctrl+Q signals quit" {
    var handler = InputHandler{ .state = .command };
    const action = handler.feed(0x11); // Ctrl+Q
    try std.testing.expectEqual(Action.quit, action);
}

test "command mode: other byte exits command mode and forwards" {
    var handler = InputHandler{ .state = .command };
    const action = handler.feed('x');
    try std.testing.expectEqual(Action{ .forward = 'x' }, action);
    try std.testing.expectEqual(InputHandler.State.normal, handler.state);
}

test "Ctrl+S twice: second Ctrl+S is forwarded" {
    var handler = InputHandler{};

    // First Ctrl+S enters command mode.
    const first = handler.feed(0x13);
    try std.testing.expectEqual(Action.none, first);
    try std.testing.expectEqual(InputHandler.State.command, handler.state);

    // Second Ctrl+S exits command mode and forwards the byte.
    const second = handler.feed(0x13);
    try std.testing.expectEqual(Action{ .forward = 0x13 }, second);
    try std.testing.expectEqual(InputHandler.State.normal, handler.state);
}

test "full quit sequence: Ctrl+S then Ctrl+Q" {
    var handler = InputHandler{};

    const enter = handler.feed(0x13); // Ctrl+S
    try std.testing.expectEqual(Action.none, enter);

    const quit = handler.feed(0x11); // Ctrl+Q
    try std.testing.expectEqual(Action.quit, quit);
}

test "command mode: arrow up switches focus up and stays in command mode" {
    var handler = InputHandler{ .state = .command };

    // Arrow up = ESC [ A
    try std.testing.expectEqual(Action.none, handler.feed(0x1B));
    try std.testing.expectEqual(Action.none, handler.feed('['));
    try std.testing.expectEqual(Action.focus_up, handler.feed('A'));
    try std.testing.expectEqual(InputHandler.State.command, handler.state);
}

test "command mode: arrow down switches focus down and stays in command mode" {
    var handler = InputHandler{ .state = .command };

    try std.testing.expectEqual(Action.none, handler.feed(0x1B));
    try std.testing.expectEqual(Action.none, handler.feed('['));
    try std.testing.expectEqual(Action.focus_down, handler.feed('B'));
    try std.testing.expectEqual(InputHandler.State.command, handler.state);
}

test "command mode: arrow right switches focus right and stays in command mode" {
    var handler = InputHandler{ .state = .command };

    try std.testing.expectEqual(Action.none, handler.feed(0x1B));
    try std.testing.expectEqual(Action.none, handler.feed('['));
    try std.testing.expectEqual(Action.focus_right, handler.feed('C'));
    try std.testing.expectEqual(InputHandler.State.command, handler.state);
}

test "command mode: arrow left switches focus left and stays in command mode" {
    var handler = InputHandler{ .state = .command };

    try std.testing.expectEqual(Action.none, handler.feed(0x1B));
    try std.testing.expectEqual(Action.none, handler.feed('['));
    try std.testing.expectEqual(Action.focus_left, handler.feed('D'));
    try std.testing.expectEqual(InputHandler.State.command, handler.state);
}

test "command mode: multiple arrow keys work without re-entering command mode" {
    var handler = InputHandler{};

    // Enter command mode
    try std.testing.expectEqual(Action.none, handler.feed(0x13));
    try std.testing.expectEqual(InputHandler.State.command, handler.state);

    // First arrow: right
    try std.testing.expectEqual(Action.none, handler.feed(0x1B));
    try std.testing.expectEqual(Action.none, handler.feed('['));
    try std.testing.expectEqual(Action.focus_right, handler.feed('C'));
    try std.testing.expectEqual(InputHandler.State.command, handler.state);

    // Second arrow: down (no Ctrl+S needed)
    try std.testing.expectEqual(Action.none, handler.feed(0x1B));
    try std.testing.expectEqual(Action.none, handler.feed('['));
    try std.testing.expectEqual(Action.focus_down, handler.feed('B'));
    try std.testing.expectEqual(InputHandler.State.command, handler.state);

    // Non-arrow key exits command mode
    const action = handler.feed('x');
    try std.testing.expectEqual(Action{ .forward = 'x' }, action);
    try std.testing.expectEqual(InputHandler.State.normal, handler.state);
}

test "command mode: unknown CSI exits command mode" {
    var handler = InputHandler{ .state = .command };

    try std.testing.expectEqual(Action.none, handler.feed(0x1B));
    try std.testing.expectEqual(Action.none, handler.feed('['));
    const action = handler.feed('Z');
    try std.testing.expectEqual(InputHandler.State.normal, handler.state);
    try std.testing.expectEqual(Action.none, action);
}

test "command mode: incomplete escape returns to normal" {
    var handler = InputHandler{ .state = .command };

    // ESC followed by non-[ should exit command mode
    try std.testing.expectEqual(Action.none, handler.feed(0x1B));
    const action = handler.feed('x');
    try std.testing.expectEqual(InputHandler.State.normal, handler.state);
    try std.testing.expectEqual(Action{ .forward = 'x' }, action);
}

test "custom prefix key: Ctrl+B enters command mode" {
    var handler = InputHandler.initWithPrefix(0x02); // Ctrl+B
    const action = handler.feed(0x02);
    try std.testing.expectEqual(Action.none, action);
    try std.testing.expectEqual(InputHandler.State.command, handler.state);
}

test "custom prefix key: default Ctrl+S is not intercepted" {
    var handler = InputHandler.initWithPrefix(0x02); // Ctrl+B
    const action = handler.feed(0x13); // Ctrl+S should be forwarded
    try std.testing.expectEqual(Action{ .forward = 0x13 }, action);
}

test "custom prefix key: double tap forwards the key" {
    var handler = InputHandler.initWithPrefix(0x02); // Ctrl+B

    const first = handler.feed(0x02);
    try std.testing.expectEqual(Action.none, first);

    // Second Ctrl+B exits command mode and forwards it
    const second = handler.feed(0x02);
    try std.testing.expectEqual(Action{ .forward = 0x02 }, second);
    try std.testing.expectEqual(InputHandler.State.normal, handler.state);
}

test "parseCtrlKey: parses ctrl-b to 0x02" {
    try std.testing.expectEqual(@as(u8, 0x02), InputHandler.parseCtrlKey("ctrl-b").?);
}

test "parseCtrlKey: parses ctrl-s to 0x13" {
    try std.testing.expectEqual(@as(u8, 0x13), InputHandler.parseCtrlKey("ctrl-s").?);
}

test "parseCtrlKey: parses ctrl-a to 0x01" {
    try std.testing.expectEqual(@as(u8, 0x01), InputHandler.parseCtrlKey("ctrl-a").?);
}

test "parseCtrlKey: returns null for invalid input" {
    try std.testing.expectEqual(@as(?u8, null), InputHandler.parseCtrlKey("invalid"));
    try std.testing.expectEqual(@as(?u8, null), InputHandler.parseCtrlKey("ctrl-"));
    try std.testing.expectEqual(@as(?u8, null), InputHandler.parseCtrlKey("ctrl-ab"));
}

test "parseKey: parses ctrl-q to [0x11]" {
    const buf = try std.testing.allocator.alloc(u8, 8);
    defer std.testing.allocator.free(buf);
    const seq = parseKey(std.testing.allocator, "ctrl-q").?;
    defer std.testing.allocator.free(seq);
    try std.testing.expectEqual(@as(usize, 1), seq.len);
    try std.testing.expectEqual(@as(u8, 0x11), seq[0]);
}

test "parseKey: parses up to ESC [ A" {
    const seq = parseKey(std.testing.allocator, "up").?;
    defer std.testing.allocator.free(seq);
    try std.testing.expectEqual(@as(usize, 3), seq.len);
    try std.testing.expectEqual(@as(u8, 0x1B), seq[0]);
    try std.testing.expectEqual(@as(u8, '['), seq[1]);
    try std.testing.expectEqual(@as(u8, 'A'), seq[2]);
}

test "parseKey: parses down to ESC [ B" {
    const seq = parseKey(std.testing.allocator, "down").?;
    defer std.testing.allocator.free(seq);
    try std.testing.expectEqual(@as(usize, 3), seq.len);
    try std.testing.expectEqual(@as(u8, 0x1B), seq[0]);
    try std.testing.expectEqual(@as(u8, '['), seq[1]);
    try std.testing.expectEqual(@as(u8, 'B'), seq[2]);
}

test "parseKey: returns null for invalid key" {
    try std.testing.expectEqual(@as(?[]const u8, null), parseKey(std.testing.allocator, "invalid"));
}

test "parseKey: parses space to 0x20" {
    const seq = parseKey(std.testing.allocator, "space").?;
    defer std.testing.allocator.free(seq);
    try std.testing.expectEqual(@as(usize, 1), seq.len);
    try std.testing.expectEqual(@as(u8, ' '), seq[0]);
}

test "parseKey: parses tab to 0x09" {
    const seq = parseKey(std.testing.allocator, "tab").?;
    defer std.testing.allocator.free(seq);
    try std.testing.expectEqual(@as(u8, 0x09), seq[0]);
}

test "parseKey: parses enter to 0x0D" {
    const seq = parseKey(std.testing.allocator, "enter").?;
    defer std.testing.allocator.free(seq);
    try std.testing.expectEqual(@as(u8, 0x0D), seq[0]);
}

test "parseKey: parses backspace to 0x7F" {
    const seq = parseKey(std.testing.allocator, "backspace").?;
    defer std.testing.allocator.free(seq);
    try std.testing.expectEqual(@as(u8, 0x7F), seq[0]);
}

test "parseKey: parses escape to 0x1B" {
    const seq = parseKey(std.testing.allocator, "escape").?;
    defer std.testing.allocator.free(seq);
    try std.testing.expectEqual(@as(u8, 0x1B), seq[0]);
}

test "parseKey: parses single letter q to its ASCII byte" {
    const seq = parseKey(std.testing.allocator, "q").?;
    defer std.testing.allocator.free(seq);
    try std.testing.expectEqual(@as(usize, 1), seq.len);
    try std.testing.expectEqual(@as(u8, 'q'), seq[0]);
}

test "parseKey: parses single digit 1 to its ASCII byte" {
    const seq = parseKey(std.testing.allocator, "1").?;
    defer std.testing.allocator.free(seq);
    try std.testing.expectEqual(@as(u8, '1'), seq[0]);
}

test "parseKey: parses punctuation to its ASCII byte" {
    const seq = parseKey(std.testing.allocator, ".").?;
    defer std.testing.allocator.free(seq);
    try std.testing.expectEqual(@as(u8, '.'), seq[0]);
}

test "parseAction: parses known actions" {
    try std.testing.expectEqual(Action.quit, parseAction("quit").?);
    try std.testing.expectEqual(Action.focus_up, parseAction("focus_up").?);
    try std.testing.expectEqual(Action.focus_down, parseAction("focus_down").?);
    try std.testing.expectEqual(Action.focus_left, parseAction("focus_left").?);
    try std.testing.expectEqual(Action.focus_right, parseAction("focus_right").?);
}

test "parseAction: returns null for unknown action" {
    const result = parseAction("unknown");
    try std.testing.expect(result == null);
}

test "custom bindings: Ctrl+J for focus_down" {
    const bindings = [_]Binding{
        .{ .action = .quit, .sequence = &[_]u8{0x11} },
        .{ .action = .focus_down, .sequence = &[_]u8{0x0A} }, // Ctrl+J
    };
    var handler = InputHandler.initWithBindings(0x13, &bindings);

    try std.testing.expectEqual(InputHandler.State.command, blk: {
        _ = handler.feed(0x13);
        break :blk handler.state;
    });

    // Ctrl+J should trigger focus_down
    const action = handler.feed(0x0A);
    try std.testing.expectEqual(Action.focus_down, action);
    try std.testing.expectEqual(InputHandler.State.command, handler.state);
}

test "custom bindings: unmatched byte still exits command mode and forwards" {
    const bindings = [_]Binding{
        .{ .action = .quit, .sequence = &[_]u8{0x11} },
    };
    var handler = InputHandler.initWithBindings(0x13, &bindings);

    _ = handler.feed(0x13); // enter command mode
    const action = handler.feed('z'); // unmatched
    try std.testing.expectEqual(Action{ .forward = 'z' }, action);
    try std.testing.expectEqual(InputHandler.State.normal, handler.state);
}

test "custom bindings: empty bindings falls back to defaults" {
    var handler = InputHandler.initWithBindings(0x13, &.{});

    _ = handler.feed(0x13); // enter command mode
    // Ctrl+Q should still work (from defaults)
    try std.testing.expectEqual(Action.quit, handler.feed(0x11));
}

test "custom bindings: arrow keys still work with defaults" {
    var handler = InputHandler.initWithBindings(0x13, &.{});

    _ = handler.feed(0x13); // enter command mode
    try std.testing.expectEqual(Action.none, handler.feed(0x1B));
    try std.testing.expectEqual(Action.none, handler.feed('['));
    try std.testing.expectEqual(Action.focus_up, handler.feed('A'));
    try std.testing.expectEqual(InputHandler.State.command, handler.state);
}
