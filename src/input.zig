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

pub const InputHandler = struct {
    state: State = .normal,
    prefix_key: u8 = default_prefix_key,
    /// If true, focus actions exit command mode (default: stay in command mode).
    exit_on_focus: bool = false,

    const State = enum { normal, command, command_esc, command_csi };

    const default_prefix_key = 0x13; // Ctrl+S
    const quit_key = 0x11; // Ctrl+Q

    pub fn initWithPrefix(prefix: u8) InputHandler {
        return .{ .prefix_key = prefix };
    }

    /// Parse a "ctrl-<letter>" string into a control character byte.
    /// Returns null if the input is not a valid ctrl-key string.
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
                if (byte == quit_key) {
                    return .quit;
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
                return switch (byte) {
                    'A' => {
                        self.state = if (self.exit_on_focus) .normal else .command;
                        return .focus_up;
                    },
                    'B' => {
                        self.state = if (self.exit_on_focus) .normal else .command;
                        return .focus_down;
                    },
                    'C' => {
                        self.state = if (self.exit_on_focus) .normal else .command;
                        return .focus_right;
                    },
                    'D' => {
                        self.state = if (self.exit_on_focus) .normal else .command;
                        return .focus_left;
                    },
                    else => {
                        self.state = .normal;
                        return .none;
                    },
                };
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
