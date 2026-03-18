// Public Domain (-) 2026-present, The Espra Core Authors.
// See the Espra Core UNLICENSE file for details.

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const locale_info = @import("locale_info.zig");

/// A two-letter ISO 639-1 language code.
pub const Language = locale_info.Language;

/// A two-letter ISO 3166-1 country code.
pub const Region = locale_info.Region;

/// A four-letter ISO 15924 script code.
pub const Script = locale_info.Script;

/// An IANA timezone identifier.
pub const Timezone = locale_info.Timezone;

pub const is_android = builtin.os.tag == .linux and builtin.abi == .android;
pub const is_ios = builtin.os.tag == .ios;
pub const is_ios_device = is_ios and builtin.abi != .ios_simulator;
pub const is_ios_simulator = is_ios and builtin.abi == .ios_simulator;
pub const is_linux = builtin.os.tag == .linux and builtin.abi != .android;
pub const is_macos = builtin.os.tag == .macos;
pub const is_windows = builtin.os.tag == .windows;

const c = if (is_linux)
    @cImport(@cInclude("locale.h"))
else if (is_macos or is_ios)
    @cImport({
        @cInclude("locale.h");
        @cInclude("sysdir.h");
    })
else
    undefined;

// NOTE(tav): This needs the appframe module to be linked.
const platform = if (is_android) struct {
    extern fn afplatform_app_path(*PlatformAppPath) callconv(.c) bool;
    extern fn afplatform_home_dir([*]u8, usize) callconv(.c) isize;
    extern fn afplatform_locale([*]u8, usize) callconv(.c) isize;
    extern fn afplatform_temp_dir([*]u8, usize) callconv(.c) isize;
    extern fn afplatform_timezone([*]u8, usize) callconv(.c) isize;
} else undefined;

const windows = if (is_windows) struct {
    const DWORD = u32;
    const GUID = extern struct {
        Data1: u32,
        Data2: u16,
        Data3: u16,
        Data4: [8]u8,
    };
    const HANDLE = std.os.windows.HANDLE;
    const HRESULT = i32;

    const FOLDERID_LocalAppData = GUID{
        .Data1 = 0xF1B32785,
        .Data2 = 0x6FBA,
        .Data3 = 0x4FCF,
        .Data4 = .{ 0x9D, 0x55, 0x7B, 0x8E, 0x7F, 0x15, 0x70, 0x91 },
    };

    const FOLDERID_RoamingAppData = GUID{
        .Data1 = 0x3EB685DB,
        .Data2 = 0x65F9,
        .Data3 = 0x4CF6,
        .Data4 = .{ 0xA0, 0x3A, 0xE3, 0xEF, 0x65, 0x72, 0x9F, 0x3D },
    };

    const S_OK: HRESULT = 0;

    extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: ?[*]u16, nSize: DWORD) callconv(.winapi) DWORD;
    extern "kernel32" fn GetWindowsDirectoryW(lpBuffer: [*]u16, uSize: DWORD) callconv(.winapi) DWORD;
    extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;
    extern "shell32" fn SHGetKnownFolderPath(rfid: *const GUID, dwFlags: DWORD, hToken: ?HANDLE, ppszPath: *[*:0]u16) callconv(.winapi) HRESULT;
} else undefined;

/// The identifiers used to construct app paths on various platforms.
pub const AppID = struct {
    /// The publisher of the app, e.g. "Microslop".
    publisher: ?[]const u8,
    /// The unique identifier of the app, e.g. "com.example.foo".
    reverse_dns: []const u8,
    /// The Unix name of the app, e.g. "foo". This is typically all lowercase.
    unix_name: []const u8,
    /// The Windows name of the app, e.g. "Foo".
    windows_name: []const u8,
};

/// Platform-specific directories for app cache, config, persistent data,
/// runtime files, and state.
pub const AppPath = struct {
    /// The directory for user-specific non-essential (cached) data.
    cache_dir: []const u8,
    /// The directory for user-specific config files.
    config_dir: []const u8,
    /// The directory for user-specific data files. This is typically used for
    /// storing data that would normally be backed up, such as databases and
    /// saved content.
    data_dir: []const u8,
    /// The directory for user-specific runtime files. This is typically used
    /// for storing runtime-scoped files that the app needs to exist at
    /// specific locations, such as domain sockets and lock files.
    runtime_dir: []const u8,
    /// The directory for user-specific state files. This is typically used for
    /// storing persisted state that would normally not be backed up, such as
    /// session state and log files.
    state_dir: []const u8,
};

/// The strategy to use for constructing app paths.
pub const AppPathStrategy = enum {
    /// Use the native mechanism on all platforms.
    native,
    /// Prefer XDG conventions on Linux and macOS. Otherwise, use the native
    /// mechanism.
    prefer_xdg,
};

/// A locale composed of language, region, and script identifiers.
pub const Locale = struct {
    language: Language,
    region: Region,
    script: Script,

    pub fn format(self: Locale, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.language.format(writer);
        try writer.writeByte('-');
        if (self.script != .unspecified) {
            try self.script.format(writer);
            try writer.writeByte('-');
        }
        try self.region.format(writer);
    }
};

const PlatformAppPath = extern struct {
    cache_dir: [*:0]const u8,
    config_dir: [*:0]const u8,
    data_dir: [*:0]const u8,
    runtime_dir: [*:0]const u8,
    state_dir: [*:0]const u8,
};

/// Get the app-related directories for the given app ID and path strategy.
pub fn app_path(allocator: Allocator, id: AppID, strategy: AppPathStrategy) !?AppPath {
    if (id.publisher) |p| {
        if (p.len == 0) {
            return error.EmptyPublisherInAppID;
        }
    }
    if (id.reverse_dns.len == 0) {
        return error.EmptyReverseDNSInAppID;
    }
    if (id.unix_name.len == 0) {
        return error.EmptyUnixNameInAppID;
    }
    if (id.windows_name.len == 0) {
        return error.EmptyWindowsNameInAppID;
    }
    if (is_android) {
        var path: PlatformAppPath = undefined;
        if (!platform.afplatform_app_path(&path)) {
            return null;
        }
        return AppPath{
            .cache_dir = try allocator.dupe(u8, std.mem.span(path.cache_dir)),
            .config_dir = try allocator.dupe(u8, std.mem.span(path.config_dir)),
            .data_dir = try allocator.dupe(u8, std.mem.span(path.data_dir)),
            .runtime_dir = try allocator.dupe(u8, std.mem.span(path.runtime_dir)),
            .state_dir = try allocator.dupe(u8, std.mem.span(path.state_dir)),
        };
    }
    switch (builtin.os.tag) {
        .ios => {
            return ios_app_path(allocator);
        },
        .linux => {
            return xdg_app_path(allocator, id.unix_name);
        },
        .macos => {
            if (strategy == .prefer_xdg) {
                return xdg_app_path(allocator, id.unix_name);
            }
            return macos_app_path(allocator, id.reverse_dns);
        },
        .windows => {
            return windows_app_path(allocator, id.publisher, id.windows_name);
        },
        else => {
            return null;
        },
    }
}

/// Get the value of an environment variable.
pub fn getenv(allocator: Allocator, name: []const u8) !?[]const u8 {
    if (is_android) {
        return null;
    }
    switch (builtin.os.tag) {
        .linux, .macos, .ios => {
            const name_z = try allocator.dupeSentinel(u8, name, 0);
            defer allocator.free(name_z);
            // NOTE(tav): This isn't thread-safe.
            if (std.c.getenv(name_z)) |env| {
                return try allocator.dupe(u8, std.mem.span(env));
            }
        },
        .windows => {
            const name16 = try std.unicode.utf8ToUtf16LeAllocZ(allocator, name);
            defer allocator.free(name16);
            // NOTE(tav): We loop in case someone changes the environment
            // variable as we're reading it.
            while (true) {
                const buf_len = windows.GetEnvironmentVariableW(name16, null, 0);
                if (buf_len == 0) {
                    return null;
                }
                const buf = try allocator.alloc(u16, buf_len);
                defer allocator.free(buf);
                const len = windows.GetEnvironmentVariableW(name16, buf.ptr, buf_len);
                if (len == 0) {
                    return null;
                }
                if (len < buf_len) {
                    return try std.unicode.utf16LeToUtf8Alloc(allocator, buf[0..len]);
                }
            }
        },
        else => {},
    }
    return null;
}

/// Get the home directory for the current user.
///
/// This defaults to $HOME on Unix-like systems and %USERPROFILE% on Windows.
pub fn home_dir(allocator: Allocator) !?[]const u8 {
    if (is_android) {
        var buf: [4096]u8 = undefined;
        const len = platform.afplatform_home_dir(&buf, buf.len);
        if (len > 0) {
            return try allocator.dupe(u8, buf[0..@intCast(len)]);
        }
        return null;
    }
    switch (builtin.os.tag) {
        .linux, .macos, .ios => {
            return try getenv(allocator, "HOME");
        },
        .windows => {
            return try getenv(allocator, "USERPROFILE");
        },
        else => {
            return null;
        },
    }
}

/// Find the locale information for the current user.
pub fn locale() Locale {
    return Locale{};
}

/// Find the temp directory for the current user.
///
/// On Unix-like systems, this will search the TMPDIR, TMP, and TEMP
/// environment variables, and fallback to the /tmp directory.
///
/// On Windows, this will search the TMP, TEMP, and USERPROFILE environment
/// variables, and fallback to the Windows directory.
pub fn temp_dir(allocator: Allocator) ![]const u8 {
    if (is_android) {
        var buf: [4096]u8 = undefined;
        const len = platform.afplatform_temp_dir(&buf, buf.len);
        if (len > 0) {
            return try allocator.dupe(u8, buf[0..@intCast(len)]);
        }
        return error.TempDirNotFound;
    }
    if (builtin.os.tag == .windows) {
        inline for (.{ "TMP", "TEMP", "USERPROFILE" }) |env| {
            const path = try getenv(allocator, env);
            if (path) |p| {
                if (p.len > 0) {
                    return p;
                }
                defer allocator.free(p);
            }
        }
        var buf: [261]u16 = undefined;
        const len = windows.GetWindowsDirectoryW(&buf, buf.len);
        if (len == 0) {
            return error.TempDirNotFound;
        }
        return try std.unicode.utf16LeToUtf8Alloc(allocator, buf[0..len]);
    }
    inline for ([_][*:0]const u8{ "TMPDIR", "TMP", "TEMP" }) |key| {
        if (std.c.getenv(key)) |tmp| {
            return try allocator.dupe(u8, std.mem.span(tmp));
        }
    }
    return try allocator.dupe(u8, "/tmp");
}

/// Get the current system timezone.
pub fn timezone() Timezone {
    return Timezone{};
}

fn ios_app_path(allocator: Allocator) !?AppPath {
    const home_z = std.c.getenv("HOME") orelse return error.HomeDirNotFound;
    const home = std.mem.span(home_z);
    return AppPath{
        .cache_dir = try std.fs.path.join(allocator, &.{ home, "Library", "Caches" }),
        .config_dir = try std.fs.path.join(allocator, &.{ home, "Library", "Preferences" }),
        .data_dir = try std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "data" }),
        .runtime_dir = try std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "runtime" }),
        .state_dir = try std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "state" }),
    };
}

fn macos_app_path(allocator: Allocator, id: []const u8) !?AppPath {
    const app_support = try sysdir_path(allocator, c.SYSDIR_DIRECTORY_APPLICATION_SUPPORT);
    defer allocator.free(app_support);
    const caches = try sysdir_path(allocator, c.SYSDIR_DIRECTORY_CACHES);
    defer allocator.free(caches);
    return AppPath{
        .cache_dir = try std.fs.path.join(allocator, &.{ caches, id }),
        .config_dir = try std.fs.path.join(allocator, &.{ app_support, id, "config" }),
        .data_dir = try std.fs.path.join(allocator, &.{ app_support, id, "data" }),
        .runtime_dir = try std.fs.path.join(allocator, &.{ app_support, id, "runtime" }),
        .state_dir = try std.fs.path.join(allocator, &.{ app_support, id, "state" }),
    };
}

fn sysdir_path(allocator: Allocator, dir: c_uint) ![]const u8 {
    var buf: [4096]u8 = undefined;
    var state = c.sysdir_start_search_path_enumeration(dir, c.SYSDIR_DOMAIN_MASK_USER);
    state = c.sysdir_get_next_search_path_enumeration(state, &buf);
    if (state == 0) {
        return error.SysdirPathNotFound;
    }
    const raw = std.mem.sliceTo(&buf, 0);
    if (raw.len > 0 and raw[0] == '~') {
        const home = std.c.getenv("HOME") orelse return error.HomeDirNotFound;
        return try std.fs.path.join(allocator, &.{ std.mem.span(home), raw[1..] });
    }
    return try allocator.dupe(u8, raw);
}

fn windows_app_path(allocator: Allocator, publisher: ?[]const u8, windows_name: []const u8) !?AppPath {
    const roaming = try windows_folder_path(allocator, publisher, windows_name, windows.FOLDERID_RoamingAppData);
    defer allocator.free(roaming);
    const local = try windows_folder_path(allocator, publisher, windows_name, windows.FOLDERID_LocalAppData);
    defer allocator.free(local);
    return AppPath{
        .cache_dir = try std.fs.path.join(allocator, &.{ local, "cache" }),
        .config_dir = try std.fs.path.join(allocator, &.{ roaming, "config" }),
        .data_dir = try std.fs.path.join(allocator, &.{ roaming, "data" }),
        .runtime_dir = try std.fs.path.join(allocator, &.{ local, "runtime" }),
        .state_dir = try std.fs.path.join(allocator, &.{ local, "state" }),
    };
}

fn windows_folder_path(allocator: Allocator, publisher: ?[]const u8, windows_name: []const u8, folder_id: windows.GUID) ![]const u8 {
    var path: [*:0]u16 = undefined;
    const hresult = windows.SHGetKnownFolderPath(&folder_id, 0, null, &path);
    if (hresult != windows.S_OK) {
        return error.WindowsFolderPathNotFound;
    }
    defer windows.CoTaskMemFree(@ptrCast(path));
    const dir = try std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.span(path));
    defer allocator.free(dir);
    if (publisher) |p| {
        return try std.fs.path.join(allocator, &.{ dir, p, windows_name });
    }
    return try std.fs.path.join(allocator, &.{ dir, windows_name });
}

fn xdg_app_path(allocator: Allocator, unix_name: []const u8) !?AppPath {
    const home_z = std.c.getenv("HOME") orelse return null;
    const home = std.mem.span(home_z);
    const cache_dir = try xdg_dir(allocator, unix_name, "XDG_CACHE_HOME", &.{ home, ".cache", unix_name });
    const config_dir = try xdg_dir(allocator, unix_name, "XDG_CONFIG_HOME", &.{ home, ".config", unix_name });
    const data_dir = try xdg_dir(allocator, unix_name, "XDG_DATA_HOME", &.{ home, ".local", "share", unix_name });
    const state_dir = try xdg_dir(allocator, unix_name, "XDG_STATE_HOME", &.{ home, ".local", "state", unix_name });
    const runtime_dir = try xdg_dir(allocator, unix_name, "XDG_RUNTIME_DIR", &.{ home, ".runtime", unix_name });
    return AppPath{
        .cache_dir = cache_dir,
        .config_dir = config_dir,
        .data_dir = data_dir,
        .runtime_dir = runtime_dir,
        .state_dir = state_dir,
    };
}

fn xdg_dir(allocator: Allocator, unix_name: []const u8, env_name: []const u8, fallback: []const []const u8) ![]const u8 {
    const dir_root = try getenv(allocator, env_name);
    const dir = blk: {
        if (dir_root) |env| {
            defer allocator.free(env);
            if (env.len > 0) {
                break :blk try std.fs.path.join(allocator, &.{ env, unix_name });
            }
        }
        break :blk try std.fs.path.join(allocator, fallback);
    };
    return dir;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const home = try home_dir(allocator) orelse "";
    std.debug.print("Home: {s}\n", .{home});
    const temp = try temp_dir(allocator);
    std.debug.print("Temp: {s}\n", .{temp});
    const path = try app_path(allocator, AppID{
        .reverse_dns = "com.example.app",
        .unix_name = "example",
        .windows_name = "Example",
        .publisher = "Publisher",
    }, .native);
    if (path) |xdg| {
        // _ = xdg;
        std.debug.print("Cache: {s}\n", .{xdg.cache_dir});
        std.debug.print("Config: {s}\n", .{xdg.config_dir});
        std.debug.print("Data: {s}\n", .{xdg.data_dir});
        std.debug.print("Runtime: {s}\n", .{xdg.runtime_dir});
        std.debug.print("State: {s}\n", .{xdg.state_dir});
    }
    // const Foox: Foo = .@"Europe/London";
    // std.debug.print("Foo: {s}\n", .{@tagName(Foox)});
}
