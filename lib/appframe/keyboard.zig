// Public Domain (-) 2026-present, The Espra Core Authors.
// See the Espra Core UNLICENSE file for details.

const std = @import("std");

/// A keyboard event.
pub const KeyEvent = struct {
    action: Action,
    logical: LogicalKey,
    is_repeat: bool, // Only set on action.pressed events
    modifiers: ModifierState,
    physical: PhysicalKeyPosition,

    pub const Action = enum {
        pressed,
        released,
    };
};

/// The layout-resolved meaning of a key.
pub const LogicalKey = union(enum) {
    unidentified,

    /// The Unicode codepoint of the pressed key for non-special keys, before
    /// any modifier keys or lock keys are applied.
    codepoint: u21,

    // Arrow Keys
    down,
    left,
    right,
    up,

    // Nav Keys
    end,
    home,
    page_down,
    page_up,

    // Editing
    backspace,
    delete,
    enter,
    insert,
    tab,

    // Modifiers
    alt,
    control,
    meta,
    shift,

    // Function Keys
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,

    // Lock Keys
    caps_lock,
    num_lock,
    scroll_lock,

    // System Keys
    context_menu,
    escape,
    pause,
    print_screen,

    // Numpad Keys
    numpad_clear,

    // Media Keys
    media_next,
    media_play_pause,
    media_previous,
    volume_down,
    volume_mute,
    volume_up,

    // Keys on International Keyboards
    jp_convert,
    jp_kana,
    jp_non_convert,
    lang_1,
    lang_2,
    lang_3,
    lang_4,
    lang_5,

    pub fn char(self: LogicalKey) ?u21 {
        return switch (self) {
            .codepoint => |c| c,
            else => null,
        };
    }

    pub fn format(self: LogicalKey, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .codepoint => |cp| try writer.print("\"{u}\"", .{cp}),
            else => try writer.writeAll(@tagName(self)),
        }
    }

    pub fn is_arrow_key(self: LogicalKey) bool {
        return switch (self) {
            .down, .left, .right, .up => true,
            else => false,
        };
    }

    pub fn is_function_key(self: LogicalKey) bool {
        return switch (self) {
            .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20, .f21, .f22, .f23, .f24 => true,
            else => false,
        };
    }

    pub fn is_modifier_key(self: LogicalKey) bool {
        return switch (self) {
            .alt,
            .control,
            .meta,
            .shift,
            => true,
            else => false,
        };
    }

    pub fn is_space(self: LogicalKey) bool {
        return self.char() == ' ';
    }
};

/// The state of modifier keys.
pub const ModifierState = packed struct(u8) {
    alt: bool = false,
    caps_lock: bool = false,
    control: bool = false,
    meta: bool = false,
    num_lock: bool = false,
    shift: bool = false,
    _padding: u2 = 0,

    /// Returns true if alt is the only non-lock modifier in effect.
    pub fn alt_only(self: ModifierState) bool {
        return self.alt and !self.control and !self.meta and !self.shift;
    }

    /// Returns true if any modifier is in effect. Ignores the state of both
    /// caps lock and num lock.
    pub fn any(self: ModifierState) bool {
        return self.alt or self.control or self.meta or self.shift;
    }

    /// Returns true if control is the only non-lock modifier in effect.
    pub fn control_only(self: ModifierState) bool {
        return self.control and !self.alt and !self.meta and !self.shift;
    }

    /// Returns true if meta is the only non-lock modifier in effect.
    pub fn meta_only(self: ModifierState) bool {
        return self.meta and !self.alt and !self.control and !self.shift;
    }

    /// Returns true if no modifier is in effect. Ignores the state of both
    /// caps lock and num lock.
    pub fn none(self: ModifierState) bool {
        return !self.any();
    }

    /// Returns true if shift is the only non-lock modifier in effect.
    pub fn shift_only(self: ModifierState) bool {
        return self.shift and !self.alt and !self.control and !self.meta;
    }
};

/// The physical position of a key, based on the corresponding location on a US
/// QWERTY keyboard as the reference point.
pub const PhysicalKeyPosition = enum(u8) {
    unidentified,

    // Letters
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,

    // Digits
    digit_0,
    digit_1,
    digit_2,
    digit_3,
    digit_4,
    digit_5,
    digit_6,
    digit_7,
    digit_8,
    digit_9,

    // Arrow Keys
    down,
    left,
    right,
    up,

    // Nav Keys
    end,
    home,
    page_down,
    page_up,

    // Editing
    backspace,
    delete,
    enter,
    insert,
    space,
    tab,

    // Symbols
    apostrophe,
    backslash,
    backtick,
    bracket_left,
    bracket_right,
    comma,
    equal,
    minus,
    period,
    semicolon,
    slash,

    // Modifiers
    alt_left,
    alt_right,
    control_left,
    control_right,
    meta_left,
    meta_right,
    shift_left,
    shift_right,

    // Function Keys
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,

    // System Keys
    caps_lock,
    context_menu,
    escape,
    pause,
    print_screen,
    scroll_lock,

    // Numpad Keys
    num_lock,
    numpad_0,
    numpad_1,
    numpad_2,
    numpad_3,
    numpad_4,
    numpad_5,
    numpad_6,
    numpad_7,
    numpad_8,
    numpad_9,
    numpad_add,
    numpad_clear,
    numpad_comma, // On Brazilian ABNT2 keyboards
    numpad_divide,
    numpad_enter,
    numpad_equal,
    numpad_multiply,
    numpad_period,
    numpad_subtract,

    // Media Keys
    media_next,
    media_play_pause,
    media_previous,
    volume_down,
    volume_mute,
    volume_up,

    // Keys on International Keyboards
    intl_backslash,
    jp_convert,
    jp_kana,
    jp_non_convert,
    jp_ro,
    jp_yen,
    lang_1,
    lang_2,
    lang_3,
    lang_4,
    lang_5,

    pub fn is_arrow_key(self: PhysicalKeyPosition) bool {
        return switch (self) {
            .down, .left, .right, .up => true,
            else => false,
        };
    }

    pub fn is_digit_key(self: PhysicalKeyPosition) bool {
        return switch (self) {
            .digit_0, .digit_1, .digit_2, .digit_3, .digit_4, .digit_5, .digit_6, .digit_7, .digit_8, .digit_9 => true,
            else => false,
        };
    }

    pub fn is_function_key(self: PhysicalKeyPosition) bool {
        return switch (self) {
            .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20, .f21, .f22, .f23, .f24 => true,
            else => false,
        };
    }

    pub fn is_letter_key(self: PhysicalKeyPosition) bool {
        return switch (self) {
            .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z => true,
            else => false,
        };
    }

    pub fn is_modifier_key(self: PhysicalKeyPosition) bool {
        return switch (self) {
            .alt_left, .alt_right, .control_left, .control_right, .meta_left, .meta_right, .shift_left, .shift_right => true,
            else => false,
        };
    }
};

pub const Shortcut = extern struct {
    key: ShortcutKey,
    modifiers: ShortcutModifiers,

    pub fn match(self: Shortcut, event: KeyEvent) bool {
        if (event.action != .pressed) {
            return false;
        }
        const key = ShortcutKey.from_logical(event.logical) orelse return false;
        return key == self.key and
            event.modifiers.alt == self.modifiers.alt and
            event.modifiers.control == self.modifiers.control and
            event.modifiers.meta == self.modifiers.meta and
            event.modifiers.shift == self.modifiers.shift;
    }
};

pub const ShortcutKey = enum(u8) {
    // Letters
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,

    // Digits
    digit_0,
    digit_1,
    digit_2,
    digit_3,
    digit_4,
    digit_5,
    digit_6,
    digit_7,
    digit_8,
    digit_9,

    // Arrow Keys
    down,
    left,
    right,
    up,

    // Nav Keys
    end,
    home,
    page_down,
    page_up,

    // Editing
    backspace,
    delete,
    enter,
    insert,
    space,
    tab,

    // Symbols
    apostrophe,
    backslash,
    backtick,
    bracket_left,
    bracket_right,
    comma,
    equal,
    minus,
    period,
    semicolon,
    slash,

    // Function Keys
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,

    // System Keys
    escape,

    pub fn from_logical_key(key: LogicalKey) ?ShortcutKey {
        return switch (key) {
            .codepoint => |cp| switch (cp) {
                'a' => .a,
                'b' => .b,
                'c' => .c,
                'd' => .d,
                'e' => .e,
                'f' => .f,
                'g' => .g,
                'h' => .h,
                'i' => .i,
                'j' => .j,
                'k' => .k,
                'l' => .l,
                'm' => .m,
                'n' => .n,
                'o' => .o,
                'p' => .p,
                'q' => .q,
                'r' => .r,
                's' => .s,
                't' => .t,
                'u' => .u,
                'v' => .v,
                'w' => .w,
                'x' => .x,
                'y' => .y,
                'z' => .z,
                '0' => .digit_0,
                '1' => .digit_1,
                '2' => .digit_2,
                '3' => .digit_3,
                '4' => .digit_4,
                '5' => .digit_5,
                '6' => .digit_6,
                '7' => .digit_7,
                '8' => .digit_8,
                '9' => .digit_9,
                ' ' => .space,
                '\'' => .apostrophe,
                '\\' => .backslash,
                '`' => .backtick,
                '[' => .bracket_left,
                ']' => .bracket_right,
                ',' => .comma,
                '=' => .equal,
                '-' => .minus,
                '.' => .period,
                ';' => .semicolon,
                '/' => .slash,
                else => null,
            },
            .down => .down,
            .left => .left,
            .right => .right,
            .up => .up,
            .end => .end,
            .home => .home,
            .page_down => .page_down,
            .page_up => .page_up,
            .backspace => .backspace,
            .delete => .delete,
            .enter => .enter,
            .insert => .insert,
            .tab => .tab,
            .f1 => .f1,
            .f2 => .f2,
            .f3 => .f3,
            .f4 => .f4,
            .f5 => .f5,
            .f6 => .f6,
            .f7 => .f7,
            .f8 => .f8,
            .f9 => .f9,
            .f10 => .f10,
            .f11 => .f11,
            .f12 => .f12,
            .f13 => .f13,
            .f14 => .f14,
            .f15 => .f15,
            .f16 => .f16,
            .f17 => .f17,
            .f18 => .f18,
            .f19 => .f19,
            .f20 => .f20,
            .f21 => .f21,
            .f22 => .f22,
            .f23 => .f23,
            .f24 => .f24,
            .escape => .escape,
            else => null,
        };
    }
};

pub const ShortcutModifiers = packed struct(u8) {
    alt: bool = false,
    control: bool = false,
    meta: bool = false,
    shift: bool = false,
    _padding: u4 = 0,
};
