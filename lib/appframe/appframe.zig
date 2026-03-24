// Public Domain (-) 2026-present, The Espra Core Authors.
// See the Espra Core UNLICENSE file for details.

const root = @import("root");
const std = @import("std");
const keyboard = @import("keyboard.zig");

const Allocator = std.mem.Allocator;
const AppData = root.AppData;

pub const KeyEvent = keyboard.KeyEvent;
pub const LogicalKey = keyboard.LogicalKey;
pub const ModifierState = keyboard.ModifierState;
pub const PhysicalKeyPosition = keyboard.PhysicalKeyPosition;
pub const Shortcut = keyboard.Shortcut;
pub const ShortcutKey = keyboard.ShortcutKey;
pub const ShortcutModifiers = keyboard.ShortcutModifiers;

// NOTE(tav): We drop events on overflow, so set the max limits to be reasonably
// high and assume that events accumulate across multiple frames.
const max_key_events = 64;
const max_pointer_events = 256;
const max_windows = 32;

pub const App = struct {
    adapter: wgpu.Adapter,
    allocator: Allocator,
    args: []const []const u8,
    device: wgpu.Device,
    instance: wgpu.Instance,
    queue: wgpu.Queue,
    slots: [max_windows]Window,

    pub fn add_menu_item(self: *App, menu_id: u64, item_id: u64, title: []const u8, shortcut: ?Shortcut) void {}

    pub fn add_menu_separator(self: *App, menu_id: u64) void {}

    pub fn add_menu_submenu(self: *App, parent_id: u64, child_id: u64) void {}

    pub fn appearance(self: *App) Appearance {
        _ = self;
        return .{
            .accent_color = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
            .dark_mode = false,
            .font_scale = 1.0,
            .high_contrast = false,
            .reduced_motion = false,
        };
    }

    pub fn chrome_insets(self: *App, window_id: u64) ChromeInsets {
        return .{
            .titlebar = 0.0,
            .left = 0.0,
            .right = 0.0,
        };
    }

    pub fn create_menu(self: *App, menu_id: u64, title: []const u8) void {}

    pub fn create_panel(self: *App, width: u32, height: u32, data: AppData) !u64 {
        return 0;
    }

    pub fn create_window(self: *App, title: []const u8, width: u32, height: u32, chrome: WindowChrome, data: AppData) !u64 {
        return 0;
    }

    pub fn close_window(self: *App, window_id: u64) void {}

    pub fn drag_out(self: *App, window_id: u64, items: []const Transferable) void {}

    pub fn hide_panel(self: *App, panel_id: u64) void {}

    pub fn is_window_decorated(self: *App, window_id: u64) bool {
        return false;
    }

    pub fn is_window_fullscreen(self: *App, window_id: u64) bool {
        return false;
    }

    pub fn is_panel_hotkey_supported(self: *App) bool {
        return false;
    }

    pub fn is_panel_visible(self: *App, panel_id: u64) bool {
        return false;
    }

    pub fn lock_cursor(self: *App, window_id: u64) void {}

    pub fn maximize_window(self: *App, window_id: u64) void {}

    pub fn minimize_window(self: *App, window_id: u64) void {}

    pub fn open_file(self: *App, window_id: u64, options: OpenFileOptions) void {}

    pub fn primary_screen(self: *App) ScreenInfo {
        _ = self;
        return .{
            .pixel_width = 0,
            .pixel_height = 0,
            .point_width = 0.0,
            .point_height = 0.0,
            .refresh_rate = 0.0,
            .scale_factor = 1.0,
        };
    }

    pub fn read_from_clipboard(self: *App) ?[]const Transferable {
        // TODO(tav): Decide if we want to make this async or not.
        return null;
    }

    pub fn register_panel_hotkey(self: *App, panel_id: u64, hotkey: Shortcut) bool {
        // Returns false if the hotkey conflicts or isn't supported, e.g. on Wayland.
        return false;
    }

    pub fn remove_menu_item(self: *App, menu_id: u64, item_id: u64) void {}

    pub fn save_file(self: *App, window_id: u64, options: SaveFileOptions) void {}

    pub fn select_directory(self: *App, window_id: u64, options: SelectDirectoryOptions) void {}

    pub fn set_cursor(self: *App, window_id: u64, cursor: CursorType) void {}

    pub fn set_main_menu(self: *App, menu_id: u64) void {}

    pub fn set_menu_item_checked(self: *App, item_id: u64, checked: bool) void {}

    pub fn set_menu_item_enabled(self: *App, item_id: u64, enabled: bool) void {}

    pub fn set_menu_item_shortcut(self: *App, item_id: u64, shortcut: Shortcut) void {}

    pub fn set_menu_item_title(self: *App, item_id: u64, title: []const u8) void {}

    pub fn set_window_max_size(self: *App, window_id: u64, width: u32, height: u32) void {}

    pub fn set_window_min_size(self: *App, window_id: u64, width: u32, height: u32) void {}

    pub fn set_window_title(self: *App, window_id: u64, title: []const u8) void {}

    pub fn set_window_titlebar_height(self: *App, window_id: u64, height: f32) void {}

    pub fn show_panel(self: *App, panel_id: u64) void {}

    pub fn toggle_fullscreen(self: *App, window_id: u64) void {}

    pub fn unlock_cursor(self: *App, window_id: u64) void {}

    pub fn warp_cursor(self: *App, window_id: u64, x: f32, y: f32) void {}

    pub fn window_screen(self: *App, window_id: u64) ScreenInfo {
        _ = self;
        _ = window_id;
        return .{
            .pixel_width = 0,
            .pixel_height = 0,
            .point_width = 0.0,
            .point_height = 0.0,
            .refresh_rate = 0.0,
            .scale_factor = 1.0,
        };
    }

    pub fn write_to_clipboard(self: *App, items: []const Transferable) bool {
        // TODO(tav): Make sure to manage the lifetime of each item's content type and data properly.
        return false;
    }
};

pub const Appearance = extern struct {
    accent_color: Color,
    dark_mode: bool,
    font_scale: f32,
    high_contrast: bool,
    reduced_motion: bool,
};

pub const ChromeInsets = extern struct {
    titlebar: f32,
    left: f32,
    right: f32,
};

pub const Color = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    pub fn equal(self: Color, other: Color) bool {
        return self.r == other.r and self.g == other.g and self.b == other.b and self.a == other.a;
    }
};

pub const CursorType = enum(u8) {
    arrow,
    busy,
    busy_blocked,
    closed_hand,
    crosshair,
    help,
    hidden,
    move,
    not_allowed,
    open_hand,
    pointer,
    resize_left_right,
    resize_nw_se,
    resize_sw_ne,
    resize_top_bottom,
    text,
    text_vertical,
    zoom_in,
    zoom_out,
};

pub const DropPhase = enum(u8) {
    cancel,
    drop,
    hover,
};

pub const HeldButtons = packed struct(u32) {
    left: bool = false,
    right: bool = false,
    middle: bool = false,
    _other: u29 = 0,

    pub fn any(self: HeldButtons) bool {
        return @as(u32, @bitCast(self)) != 0;
    }

    pub fn is_held(self: HeldButtons, button: MouseButton) bool {
        return (@as(u32, @bitCast(self)) >> @intFromEnum(button)) & 1 == 1;
    }

    pub fn set(self: *HeldButtons, button: MouseButton, pressed: bool) void {
        const backing: u32 = @bitCast(self.*);
        if (pressed) {
            self.* = @bitCast(backing | (@as(u32, 1) << @intFromEnum(button)));
        } else {
            self.* = @bitCast(backing & ~(@as(u32, 1) << @intFromEnum(button)));
        }
    }
};

pub const OpenFileOptions = struct {
    filters: []const OpenFileFilter = &.{},
    multi_select: bool = false,
};

pub const OpenFileFilter = struct {
    extensions: []const []const u8,
    label: []const u8,
};

pub const Frame = struct {
    cursor_dx: f32,
    cursor_dy: f32,
    focus_changed: bool,
    focused: bool,
    key_events_buf: [max_key_events]KeyEvent,
    key_events_count: u32,
    pixel_height: u32,
    pixel_width: u32,
    point_height: f32,
    point_width: f32,
    pointer_events_buf: [max_pointer_events]PointerEvent,
    pointer_events_count: u32,
    resized: bool,
    scale_factor: f32,
    scroll_dx: f32,
    scroll_dy: f32,
    seconds_since_last_frame: f32,

    pub fn flip_y(self: *const Frame, y: f32) f32 {
        _ = self;
        // return self.point_height - y;
        return y;
    }

    pub fn key_events(self: *const Frame) []const KeyEvent {
        return self.key_events_buf[0..self.key_events_count];
    }

    pub fn pointer_events(self: *const Frame) []const PointerEvent {
        return self.pointer_events_buf[0..self.pointer_events_count];
    }
};

pub const MouseButton = enum(u5) {
    left,
    right,
    middle,
    _, // For device-specific buttons.
};

pub const MouseState = struct {
    held: HeldButtons,
    trigger: ?MouseButton,
};

const PendingState = struct {
    cursor_dx: f32 = 0,
    cursor_dy: f32 = 0,
    focus_changed: bool = false,
    focused: bool = false,
    key_events: [max_key_events]KeyEvent = undefined,
    key_events_count: u32 = 0,
    pixel_height: u32 = 0,
    pixel_width: u32 = 0,
    point_height: f32 = 0,
    point_width: f32 = 0,
    pointer_events: [max_pointer_events]PointerEvent = undefined,
    pointer_events_count: u32 = 0,
    resized: bool = false,
    scale_factor: f32 = 1.0,
    scroll_dx: f32 = 0,
    scroll_dy: f32 = 0,
};

pub const PointerEvent = struct {
    click_count: u8,
    mouse: MouseState,
    phase: PointerPhase,
    pointer_id: u32, // Unique for each touch contact/finger. Always 0 for mouse and pen.
    pointer_type: PointerType,
    pressure: f32,
    x: f32,
    y: f32,
};

pub const PointerPhase = enum(u8) {
    cancel,
    drag,
    hover,
    press,
    release,
};

pub const PointerType = enum(u8) {
    mouse,
    pen,
    touch,
};

pub const SaveFileFormat = struct {
    extension: []const u8,
    label: []const u8,
};

pub const SaveFileOptions = struct {
    default_filename: ?[]const u8 = null,
    formats: []const SaveFileFormat = &.{},
};

pub const ScreenInfo = extern struct {
    pixel_height: u32,
    pixel_width: u32,
    point_height: f32,
    point_width: f32,
    refresh_rate: f32,
    scale_factor: f32,
};

pub const SelectDirectoryOptions = struct {
    multi_select: bool = false,
};

pub const TransferFormat = union(enum) {
    content_type: []const u8,
    image_jpeg,
    image_png,
    text_html,
    text_rtf,
    text_utf8,
    urls,
};

pub const Transferable = struct {
    format: TransferFormat,
    data: []const u8,
};

pub const Window = struct {
    data: AppData,
    id: u64,
    pixel_height: u32,
    pixel_width: u32,
    point_height: f32,
    point_width: f32,
    scale_factor: f32,

    format: wgpu.TextureFormat,
    mutex: std.Thread.Mutex,
    pending: PendingState,
    surface: wgpu.Surface,
};

pub const WindowChrome = enum(u8) {
    default,
    minimal,
};

pub const WindowInitEvent = extern struct {
    context: ?*anyopaque,
    pixel_height: u32,
    pixel_width: u32,
    point_height: f32,
    point_width: f32,
    scale_factor: f32,
    surface: *anyopaque,
    window_id: u64,
};

pub fn parse_drop_file_paths(allocator: Allocator, items: []const Transferable) !?[][]const u8 {
    _ = allocator;
    _ = items;
    return null;
}
