// Public Domain (-) 2026-present, The Espra Core Authors.
// See the Espra Core UNLICENSE file for details.

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const locale_info = @import("locale_info.zig");

const c_locale = if (builtin.os.tag == .linux or builtin.os.tag == .macos or builtin.os.tag == .ios)
    @cImport(@cInclude("locale.h"))
else
    undefined;

const c_sysdir = if (builtin.os.tag == .macos or builtin.os.tag == .ios)
    @cImport(@cInclude("sysdir.h"))
else
    undefined;

const windows = if (builtin.os.tag == .windows)
    @import("sys_windows.zig")
else
    undefined;

pub const Language = locale_info.Language;
pub const Region = locale_info.Region;
pub const Timezone = locale_info.Timezone;

extern fn sys_platform_app_path(*PlatformAppPath) callconv(.c) bool;
extern fn sys_platform_home_dir([*]u8, usize) callconv(.c) isize;
extern fn sys_platform_locale([*]u8, usize) callconv(.c) isize;
extern fn sys_platform_temp_dir([*]u8, usize) callconv(.c) isize;
extern fn sys_platform_timezone([*]u8, usize) callconv(.c) isize;

const is_android = builtin.os.tag == .linux and builtin.abi == .android;

pub const AppID = struct {
    identifier: []const u8,
    unix_name: []const u8,
    windows_name: []const u8,
    publisher: []const u8,
};

pub const AppPath = struct {
    cache_dir: []const u8,
    config_dir: []const u8,
    data_dir: []const u8,
    runtime_dir: []const u8,
    state_dir: []const u8,
};

pub const Locale = struct {
    language: Language,
    region: Region,
};

pub const PathMode = enum {
    /// Use the XDG spec on all Unix platforms, including macOS. Otherwise, use
    /// the native mechanism.
    cli,
    /// Use the native mechanism on all platforms.
    native,
};

const PlatformAppPath = extern struct {
    cache_dir: [*:0]const u8,
    config_dir: [*:0]const u8,
    data_dir: [*:0]const u8,
    runtime_dir: [*:0]const u8,
    state_dir: [*:0]const u8,
};

pub fn app_path(allocator: Allocator, id: AppID, mode: PathMode) AppPath {
    _ = allocator;
    _ = id;
    _ = mode;
    return AppPath{};
}

pub fn home_dir(allocator: Allocator) ![]const u8 {
    if (is_android) {
        var buf: [4096]u8 = undefined;
        const len = sys_platform_home_dir(&buf, buf.len);
        if (len > 0) {
            return try allocator.dupe(u8, buf[0..@intCast(len)]);
        }
        return error.HomeDirNotFound;
    }
    switch (builtin.os.tag) {
        .linux, .macos, .ios => {
            if (std.c.getenv("HOME")) |home| {
                return try allocator.dupe(u8, std.mem.span(home));
            }
        },
        .windows => {
            const buf = try allocator.alloc(u16, 32767);
            defer allocator.free(buf);
            const len = windows.GetEnvironmentVariableW(
                comptime std.unicode.utf8ToUtf16LeStringLiteral("USERPROFILE"),
                buf.ptr,
                @intCast(buf.len),
            );
            if (len > 0) {
                return try std.unicode.utf16leToUtf8Alloc(allocator, buf[0..@intCast(len)]);
            }
        },
        else => {},
    }
    return error.HomeDirNotFound;
}

pub fn locale() Locale {
    return Locale{};
}

pub fn temp_dir(allocator: Allocator) ![]const u8 {
    if (is_android) {
        var buf: [4096]u8 = undefined;
        const len = sys_platform_temp_dir(&buf, buf.len);
        if (len > 0) {
            return try allocator.dupe(u8, buf[0..@intCast(len)]);
        }
        return error.TempDirNotFound;
    }
    if (builtin.os.tag == .windows) {
        const buf = try allocator.alloc(u16, 32767);
        defer allocator.free(buf);
        const len = windows.GetTempPathW(@intCast(buf.len), buf.ptr);
        if (len > 0) {
            return try std.unicode.utf16leToUtf8Alloc(allocator, buf[0..@intCast(len)]);
        }
        return error.TempDirNotFound;
    }
    inline for ([_][*:0]const u8{ "TMPDIR", "TMP", "TEMP" }) |key| {
        if (std.c.getenv(key)) |tmp| {
            return try allocator.dupe(u8, std.mem.span(tmp));
        }
    }
    return try allocator.dupe(u8, "/tmp");
}

pub fn timezone() Timezone {
    return Timezone{};
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const home = try home_dir(allocator);
    defer allocator.free(home);
    std.debug.print("Home: {s}\n", .{home});
    const temp = try temp_dir(allocator);
    std.debug.print("Temp: {s}\n", .{temp});
}
