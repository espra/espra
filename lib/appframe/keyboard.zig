const std = @import("std");

/// KeyEvent represents a keyboard event.
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

/// LogicalKey represents the layout-resolved meaning of a key.
pub const LogicalKey = union(enum) {
    unidentified,

    /// Codepoint holds the Unicode codepoint of the pressed key for
    /// non-special keys, before applying modifier keys or lock keys.
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
};

/// ModifierState represents which modifier keys are in effect.
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

/// PhysicalKeyPosition represents the physical position of a key. It uses the
/// corresponding location on a US QWERTY keyboard as the reference.
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
