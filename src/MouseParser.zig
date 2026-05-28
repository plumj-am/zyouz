const std = @import("std");

pub const MouseButton = enum {
    left,
    middle,
    right,
    scroll_up,
    scroll_down,
    scroll_left,
    scroll_right,
    none,
};

pub const MouseEventKind = enum {
    press,
    release,
    drag,
    motion,
};

pub const Modifiers = packed struct {
    shift: bool = false,
    meta: bool = false,
    ctrl: bool = false,
};

pub const MouseEvent = struct {
    button: MouseButton,
    col: u16,
    row: u16,
    kind: MouseEventKind,
    modifiers: Modifiers = .{},
    /// Raw SGR button code, preserved for accurate passthrough forwarding.
    button_code: u16 = 0,

    /// Format this event as an SGR mouse sequence with pane-local coordinates.
    /// pane_col/pane_row are the pane's top-left corner in terminal coordinates.
    pub fn formatSgr(self: MouseEvent, buf: []u8, pane_col: u16, pane_row: u16) []const u8 {
        const local_col = self.col - pane_col + 1; // 1-based
        const local_row = self.row - pane_row + 1;
        const final: u8 = if (self.kind == .release) 'm' else 'M';
        const len = std.fmt.bufPrint(buf, "\x1b[<{d};{d};{d}{c}", .{
            self.button_code, local_col, local_row, final,
        }) catch return "";
        return len;
    }
};

pub const Result = union(enum) {
    /// Byte is not part of a mouse sequence; pass through to next handler.
    passthrough: u8,
    /// Byte consumed as part of a potential/actual mouse sequence.
    consumed,
    /// Complete mouse event parsed.
    event: MouseEvent,
    /// ESC was consumed but sequence is not mouse-related.
    /// Caller should pass through ESC (0x1b) then this byte.
    escape_passthrough: u8,
    /// ESC [ was consumed but sequence is not mouse-related.
    /// Caller should pass through ESC, '[', then this byte.
    csi_passthrough: u8,
};

pub const State = enum {
    ground,
    esc,
    csi,
    params,
};

const MouseParser = @This();

state: State = .ground,
param_buf: [32]u8 = undefined,
param_len: u8 = 0,

pub fn feed(self: *MouseParser, byte: u8) Result {
    switch (self.state) {
        .ground => {
            if (byte == 0x1B) {
                self.state = .esc;
                return .consumed;
            }
            return .{ .passthrough = byte };
        },
        .esc => {
            if (byte == '[') {
                self.state = .csi;
                return .consumed;
            }
            self.state = .ground;
            return .{ .escape_passthrough = byte };
        },
        .csi => {
            if (byte == '<') {
                self.state = .params;
                self.param_len = 0;
                return .consumed;
            }
            self.state = .ground;
            return .{ .csi_passthrough = byte };
        },
        .params => {
            if ((byte >= '0' and byte <= '9') or byte == ';') {
                if (self.param_len < self.param_buf.len) {
                    self.param_buf[self.param_len] = byte;
                    self.param_len += 1;
                }
                return .consumed;
            }
            if (byte == 'M' or byte == 'm') {
                const event = self.parseParams(byte);
                self.state = .ground;
                self.param_len = 0;
                if (event) |ev| {
                    return .{ .event = ev };
                }
                return .consumed;
            }
            // Invalid byte — discard sequence
            self.state = .ground;
            self.param_len = 0;
            return .consumed;
        },
    }
}

fn parseParams(self: *const MouseParser, final: u8) ?MouseEvent {
    const params = self.param_buf[0..self.param_len];

    // Parse "button;col;row"
    var parts: [3]u16 = .{ 0, 0, 0 };
    var part_idx: usize = 0;

    for (params) |ch| {
        if (ch == ';') {
            part_idx += 1;
            if (part_idx >= 3) return null;
        } else {
            parts[part_idx] = parts[part_idx] * 10 + @as(u16, ch - '0');
        }
    }

    if (part_idx != 2) return null;

    const button_code = parts[0];
    const col = if (parts[1] > 0) parts[1] - 1 else 0;
    const row = if (parts[2] > 0) parts[2] - 1 else 0;

    // Bit layout: [7:6]=scroll, [5]=motion, [4]=ctrl, [3]=meta, [2]=shift, [1:0]=button
    const is_motion = (button_code & 32) != 0;
    const modifiers = Modifiers{
        .shift = (button_code & 4) != 0,
        .meta = (button_code & 8) != 0,
        .ctrl = (button_code & 16) != 0,
    };
    // Strip motion bit (32) and modifier bits (4, 8, 16) to get base button.
    const base_button = button_code & ~@as(u16, 32 | 4 | 8 | 16);

    const button: MouseButton = switch (base_button) {
        0 => .left,
        1 => .middle,
        2 => .right,
        3 => .none,
        64 => .scroll_up,
        65 => .scroll_down,
        66 => .scroll_left,
        67 => .scroll_right,
        else => .none,
    };

    const kind: MouseEventKind = if (is_motion and base_button == 3)
        .motion
    else if (is_motion)
        .drag
    else if (final == 'M')
        .press
    else
        .release;

    return .{
        .button = button,
        .col = col,
        .row = row,
        .kind = kind,
        .modifiers = modifiers,
        .button_code = button_code,
    };
}

// --- Tests ---

test "non-escape byte passes through in ground state" {
    var parser = MouseParser{};
    const result = parser.feed('a');
    try std.testing.expectEqual(Result{ .passthrough = 'a' }, result);
}

test "ESC byte is consumed and enters esc state" {
    var parser = MouseParser{};
    const result = parser.feed(0x1B);
    try std.testing.expectEqual(Result.consumed, result);
    try std.testing.expectEqual(State.esc, parser.state);
}

test "ESC followed by '[' is consumed and enters csi state" {
    var parser = MouseParser{ .state = .esc };
    const result = parser.feed('[');
    try std.testing.expectEqual(Result.consumed, result);
    try std.testing.expectEqual(State.csi, parser.state);
}

test "ESC followed by non-'[' emits escape_passthrough" {
    var parser = MouseParser{ .state = .esc };
    const result = parser.feed('x');
    try std.testing.expectEqual(Result{ .escape_passthrough = 'x' }, result);
    try std.testing.expectEqual(State.ground, parser.state);
}

test "ESC [ followed by '<' enters params state" {
    var parser = MouseParser{ .state = .csi };
    const result = parser.feed('<');
    try std.testing.expectEqual(Result.consumed, result);
    try std.testing.expectEqual(State.params, parser.state);
}

test "ESC [ followed by non-'<' emits csi_passthrough" {
    var parser = MouseParser{ .state = .csi };
    const result = parser.feed('A');
    try std.testing.expectEqual(Result{ .csi_passthrough = 'A' }, result);
    try std.testing.expectEqual(State.ground, parser.state);
}

test "SGR left click at (1,1) parsed correctly" {
    var parser = MouseParser{};

    // Feed: ESC [ < 0 ; 1 ; 1 M
    try std.testing.expectEqual(Result.consumed, parser.feed(0x1B));
    try std.testing.expectEqual(Result.consumed, parser.feed('['));
    try std.testing.expectEqual(Result.consumed, parser.feed('<'));
    try std.testing.expectEqual(Result.consumed, parser.feed('0'));
    try std.testing.expectEqual(Result.consumed, parser.feed(';'));
    try std.testing.expectEqual(Result.consumed, parser.feed('1'));
    try std.testing.expectEqual(Result.consumed, parser.feed(';'));
    try std.testing.expectEqual(Result.consumed, parser.feed('1'));

    const result = parser.feed('M');
    try std.testing.expectEqual(Result{ .event = .{
        .button = .left,
        .col = 0, // 1-based → 0-based
        .row = 0,
        .kind = .press,
        .button_code = 0,
    } }, result);
    try std.testing.expectEqual(State.ground, parser.state);
}

test "SGR left click release uses lowercase m" {
    var parser = MouseParser{};

    // Feed: ESC [ < 0 ; 5 ; 3 m
    for ("\x1b[<0;5;3") |byte| {
        _ = parser.feed(byte);
    }

    const result = parser.feed('m');
    try std.testing.expectEqual(Result{ .event = .{
        .button = .left,
        .col = 4, // 5 → 4 (0-based)
        .row = 2, // 3 → 2 (0-based)
        .kind = .release,
        .button_code = 0,
    } }, result);
}

test "SGR right click (button 2)" {
    var parser = MouseParser{};

    for ("\x1b[<2;10;20") |byte| {
        _ = parser.feed(byte);
    }

    const result = parser.feed('M');
    try std.testing.expectEqual(Result{ .event = .{
        .button = .right,
        .col = 9,
        .row = 19,
        .kind = .press,
        .button_code = 2,
    } }, result);
}

test "SGR scroll up (button 64)" {
    var parser = MouseParser{};

    for ("\x1b[<64;5;5") |byte| {
        _ = parser.feed(byte);
    }

    const result = parser.feed('M');
    try std.testing.expectEqual(MouseButton.scroll_up, result.event.button);
}

test "SGR scroll down (button 65)" {
    var parser = MouseParser{};

    for ("\x1b[<65;5;5") |byte| {
        _ = parser.feed(byte);
    }

    const result = parser.feed('M');
    try std.testing.expectEqual(MouseButton.scroll_down, result.event.button);
}

test "multi-digit coordinates parsed correctly" {
    var parser = MouseParser{};

    for ("\x1b[<0;120;45") |byte| {
        _ = parser.feed(byte);
    }

    const result = parser.feed('M');
    try std.testing.expectEqual(@as(u16, 119), result.event.col); // 120 → 119
    try std.testing.expectEqual(@as(u16, 44), result.event.row); // 45 → 44
}

test "parser resets to ground after complete event" {
    var parser = MouseParser{};

    for ("\x1b[<0;1;1") |byte| {
        _ = parser.feed(byte);
    }
    _ = parser.feed('M');

    // Next non-escape byte should pass through
    try std.testing.expectEqual(Result{ .passthrough = 'a' }, parser.feed('a'));
}

test "formatSgr produces correct SGR sequence for left click" {
    const ev = MouseEvent{
        .button = .left,
        .col = 10,
        .row = 5,
        .kind = .press,
        .button_code = 0,
    };
    var buf: [32]u8 = undefined;
    // Pane at (col=5, row=2) → local coords = (6, 4) → SGR 1-based = (7, 5)
    const result = ev.formatSgr(&buf, 5, 2);
    try std.testing.expectEqualStrings("\x1b[<0;6;4M", result);
}

test "formatSgr produces release with lowercase m" {
    const ev = MouseEvent{
        .button = .left,
        .col = 10,
        .row = 5,
        .kind = .release,
        .button_code = 0,
    };
    var buf: [32]u8 = undefined;
    const result = ev.formatSgr(&buf, 5, 2);
    try std.testing.expectEqualStrings("\x1b[<0;6;4m", result);
}

test "formatSgr preserves raw button code for modifiers" {
    // Button code 32 = motion event with left button
    const ev = MouseEvent{
        .button = .left,
        .col = 20,
        .row = 10,
        .kind = .press,
        .button_code = 32,
    };
    var buf: [32]u8 = undefined;
    const result = ev.formatSgr(&buf, 0, 0);
    try std.testing.expectEqualStrings("\x1b[<32;21;11M", result);
}

test "formatSgr with pane at origin" {
    const ev = MouseEvent{
        .button = .right,
        .col = 0,
        .row = 0,
        .kind = .press,
        .button_code = 2,
    };
    var buf: [32]u8 = undefined;
    const result = ev.formatSgr(&buf, 0, 0);
    try std.testing.expectEqualStrings("\x1b[<2;1;1M", result);
}

test "parsed event preserves button_code" {
    var parser = MouseParser{};
    for ("\x1b[<2;10;20") |byte| {
        _ = parser.feed(byte);
    }
    const result = parser.feed('M');
    try std.testing.expectEqual(@as(u16, 2), result.event.button_code);
}

test "SGR drag event (button code 32) parsed as drag with left button" {
    var parser = MouseParser{};

    for ("\x1b[<32;10;5") |byte| {
        _ = parser.feed(byte);
    }

    const result = parser.feed('M');
    try std.testing.expectEqual(MouseEventKind.drag, result.event.kind);
    try std.testing.expectEqual(MouseButton.left, result.event.button);
    try std.testing.expectEqual(@as(u16, 9), result.event.col); // 10 → 9 (0-based)
    try std.testing.expectEqual(@as(u16, 4), result.event.row); // 5 → 4 (0-based)
    try std.testing.expectEqual(@as(u16, 32), result.event.button_code);
}

test "SGR drag with right button (button code 34)" {
    var parser = MouseParser{};

    for ("\x1b[<34;20;15") |byte| {
        _ = parser.feed(byte);
    }

    const result = parser.feed('M');
    try std.testing.expectEqual(MouseEventKind.drag, result.event.kind);
    try std.testing.expectEqual(MouseButton.right, result.event.button);
}

test "SGR scroll left (button 66)" {
    var parser = MouseParser{};

    for ("\x1b[<66;5;5") |byte| {
        _ = parser.feed(byte);
    }

    const result = parser.feed('M');
    try std.testing.expectEqual(MouseButton.scroll_left, result.event.button);
}

test "SGR scroll right (button 67)" {
    var parser = MouseParser{};

    for ("\x1b[<67;5;5") |byte| {
        _ = parser.feed(byte);
    }

    const result = parser.feed('M');
    try std.testing.expectEqual(MouseButton.scroll_right, result.event.button);
}

test "SGR motion event (button code 35) parsed as motion with no button" {
    var parser = MouseParser{};

    // button code 35 = 32 (motion bit) + 3 (no button held)
    for ("\x1b[<35;15;10") |byte| {
        _ = parser.feed(byte);
    }

    const result = parser.feed('M');
    try std.testing.expectEqual(MouseEventKind.motion, result.event.kind);
    try std.testing.expectEqual(MouseButton.none, result.event.button);
    try std.testing.expectEqual(@as(u16, 14), result.event.col);
    try std.testing.expectEqual(@as(u16, 9), result.event.row);
    try std.testing.expectEqual(@as(u16, 35), result.event.button_code);
}

test "formatSgr produces press with uppercase M for motion" {
    const ev = MouseEvent{
        .button = .none,
        .col = 5,
        .row = 3,
        .kind = .motion,
        .button_code = 35,
    };
    var buf: [32]u8 = undefined;
    const result = ev.formatSgr(&buf, 0, 0);
    try std.testing.expectEqualStrings("\x1b[<35;6;4M", result);
}

test "invalid byte in params state resets to ground" {
    var parser = MouseParser{};

    for ("\x1b[<0;1;") |byte| {
        _ = parser.feed(byte);
    }

    // Invalid byte (not digit, semicolon, M, or m)
    const result = parser.feed('X');
    try std.testing.expectEqual(Result.consumed, result);
    try std.testing.expectEqual(State.ground, parser.state);
}
