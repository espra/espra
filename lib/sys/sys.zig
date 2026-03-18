// Public Domain (-) 2026-present, The Espra Core Authors.
// See the Espra Core UNLICENSE file for details.

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const locale_info = @import("locale_info.zig");

/// A BCP 47 language subtag for frequently seen languages.
///
/// Uses ISO 639-1 two-letter codes where available, and ISO 639-2 three-letter
/// codes otherwise.
pub const Language = locale_info.Language;

/// A two-letter ISO 3166-1 country code or the special "001" world region.
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
else if (is_macos)
    @cImport({
        @cInclude("sysdir.h");
    })
else
    undefined;

const objc = if (is_macos or is_ios) struct {
    extern "objc" fn objc_getClass(name: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "objc" fn objc_msgSend() callconv(.c) void;
    extern "objc" fn sel_registerName(name: [*:0]const u8) callconv(.c) ?*anyopaque;
} else undefined;

// NOTE(tav): This needs the appframe module to be linked.
const platform = if (is_android or is_ios) struct {
    extern fn afplatform_app_path(*PlatformAppPath) callconv(.c) bool;
    extern fn afplatform_home_dir([*]u8, usize) callconv(.c) isize;
    extern fn afplatform_locale([*]u8, usize) callconv(.c) isize;
    extern fn afplatform_temp_dir([*]u8, usize) callconv(.c) isize;
    extern fn afplatform_timezone([*]u8, usize) callconv(.c) isize;
} else undefined;

const windows = if (is_windows) struct {
    const BOOLEAN = u8;
    const DWORD = u32;
    const DYNAMIC_TIME_ZONE_INFORMATION = extern struct {
        Bias: LONG,
        StandardName: [32]WCHAR,
        StandardDate: SYSTEMTIME,
        StandardBias: LONG,
        DaylightName: [32]WCHAR,
        DaylightDate: SYSTEMTIME,
        DaylightBias: LONG,
        TimeZoneKeyName: [128]WCHAR,
        DynamicDaylightTimeDisabled: BOOLEAN,
    };
    const GUID = extern struct {
        Data1: u32,
        Data2: u16,
        Data3: u16,
        Data4: [8]u8,
    };
    const HANDLE = std.os.windows.HANDLE;
    const HRESULT = i32;
    const SYSTEMTIME = extern struct {
        wYear: WORD,
        wMonth: WORD,
        wDayOfWeek: WORD,
        wHour: WORD,
        wMinute: WORD,
        wSecond: WORD,
        wMilliseconds: WORD,
    };
    const LONG = i32;
    const WCHAR = u16;
    const WORD = u16;

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

    extern "kernel32" fn GetDynamicTimeZoneInformation(pTimeZoneInformation: *DYNAMIC_TIME_ZONE_INFORMATION) callconv(.winapi) DWORD;
    extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: ?[*]u16, nSize: DWORD) callconv(.winapi) DWORD;
    extern "kernel32" fn GetUserDefaultLocaleName(lpLocaleName: [*]u16, cchLocaleName: c_int) callconv(.winapi) c_int;
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

/// A BCP 47 locale composed of language, region, and script identifiers.
pub const Locale = struct {
    language: Language,
    region: ?Region,
    script: ?Script,

    pub fn format(self: Locale, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(@tagName(self.language));
        if (self.script) |s| {
            try writer.writeByte('-');
            try writer.writeAll(@tagName(s));
        }
        if (self.region) |r| {
            try writer.writeByte('-');
            try writer.writeAll(@tagName(r));
        }
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
///
/// Defaults to English if the language cannot be determined.
pub fn locale() Locale {
    if (is_android) {
        var buf: [64]u8 = undefined;
        const len = platform.afplatform_locale(&buf, buf.len);
        if (len > 0) {
            if (parse_bcp47_locale(buf[0..@intCast(len)])) |val| {
                return val;
            }
        }
        return Locale{
            .language = .en,
            .region = null,
            .script = null,
        };
    }
    switch (builtin.os.tag) {
        .linux => {
            if (locale_from_env()) |val| {
                return val;
            }
        },
        .macos => {
            if (locale_from_env()) |val| {
                return val;
            }
            if (nslocale()) |val| {
                return val;
            }
        },
        .ios => {
            if (nslocale()) |val| {
                return val;
            }
        },
        .windows => {
            var buf16: [85]u16 = undefined;
            const len = windows.GetUserDefaultLocaleName(&buf16, buf16.len);
            if (len > 0) {
                var buf: [256]u8 = undefined;
                const n = std.unicode.utf16LeToUtf8(&buf, buf16[0..@intCast(len - 1)]) catch 0;
                if (n > 0) {
                    if (parse_bcp47_locale(buf[0..n])) |val| {
                        return val;
                    }
                }
            }
        },
        else => {},
    }
    return Locale{
        .language = .en,
        .region = null,
        .script = null,
    };
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
    inline for ([_][*:0]const u8{ "TMPDIR", "TMP", "TEMP" }) |env| {
        if (std.c.getenv(env)) |tmp| {
            return try allocator.dupe(u8, std.mem.span(tmp));
        }
    }
    return try allocator.dupe(u8, "/tmp");
}

/// Get the current system timezone.
///
/// Defaults to UTC if a known timezone cannot be determined.
///
/// If a region is provided, then on Windows, it will try and match the Windows
/// timezone to the region-appropriate IANA timezone.
pub fn timezone(io: Io, region: ?Region) Timezone {
    if (is_android or is_ios) {
        var buf: [64]u8 = undefined;
        const len = platform.afplatform_timezone(&buf, buf.len);
        if (len > 0) {
            return Timezone.parse(buf[0..@intCast(len)]) orelse .UTC;
        }
        return .UTC;
    }
    switch (builtin.os.tag) {
        .linux => {
            return timezone_from_env() orelse timezone_from_etc_timezone(io) orelse timezone_from_etc_localtime(io) orelse .UTC;
        },
        .macos => {
            return timezone_from_env() orelse timezone_from_etc_localtime(io) orelse .UTC;
        },
        .windows => {
            var info: windows.DYNAMIC_TIME_ZONE_INFORMATION = undefined;
            _ = windows.GetDynamicTimeZoneInformation(&info);
            const tz16 = std.mem.sliceTo(&info.TimeZoneKeyName, 0);
            var tz_buf: [64]u8 = undefined;
            const len = std.unicode.utf16LeToUtf8(&tz_buf, tz16) catch return .UTC;
            return Timezone.from_windows_name(tz_buf[0..len], region) orelse .UTC;
        },
        else => {
            return .UTC;
        },
    }
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

fn is_all_digits(s: []const u8) bool {
    for (s) |ch| {
        if (ch < '0' or ch > '9') {
            return false;
        }
    }
    return true;
}

fn is_all_upper(s: []const u8) bool {
    for (s) |ch| {
        if (ch < 'A' or ch > 'Z') {
            return false;
        }
    }
    return true;
}

fn locale_from_env() ?Locale {
    inline for (.{ "LC_ALL", "LC_MESSAGES", "LANG" }) |env| {
        if (std.c.getenv(env)) |env_z| {
            const val = std.mem.span(env_z);
            if (val.len > 0) {
                return parse_posix_locale(val);
            }
        }
    }
    return null;
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

fn nslocale() ?Locale {
    const NSLocale: *anyopaque = @ptrCast(objc.objc_getClass("NSLocale") orelse return null);
    const currentLocale: *anyopaque = @ptrCast(objc.sel_registerName("currentLocale") orelse return null);
    const localeIdentifier: *anyopaque = @ptrCast(objc.sel_registerName("localeIdentifier") orelse return null);
    const UTF8String: *anyopaque = @ptrCast(objc.sel_registerName("UTF8String") orelse return null);
    const send: *const fn (*anyopaque, *anyopaque) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const loc = send(NSLocale, currentLocale) orelse return null;
    const ident = send(loc, localeIdentifier) orelse return null;
    const cstr: [*:0]const u8 = @ptrCast(send(ident, UTF8String) orelse return null);
    const str = std.mem.span(cstr);
    if (str.len > 64) {
        return null;
    }
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..str.len], str);
    std.mem.replaceScalar(u8, buf[0..str.len], '_', '-');
    return parse_bcp47_locale(buf[0..str.len]);
}

fn parse_bcp47_locale(val: []const u8) ?Locale {
    var parts = std.mem.splitScalar(u8, val, '-');
    var language: ?Language = null;
    var region: ?Region = null;
    var script: ?Script = null;
    while (parts.next()) |part| {
        if (part.len == 4) {
            if (Script.parse(part)) |s| {
                script = s;
            }
        }
        if (is_all_upper(part) or is_all_digits(part)) {
            if (Region.parse(part)) |r| {
                region = r;
            }
        }
        if (Language.parse(part)) |l| {
            language = l;
        }
    }
    if (language == null and region == null and script == null) {
        return null;
    }
    return Locale{
        .language = language orelse .en,
        .region = region,
        .script = script,
    };
}

fn parse_posix_locale(val: []const u8) ?Locale {
    var base = val;
    if (std.mem.indexOfScalar(u8, base, '@')) |idx| {
        base = base[0..idx];
    }
    if (std.mem.indexOfScalar(u8, base, '.')) |idx| {
        base = base[0..idx];
    }
    var language: ?Language = null;
    var region: ?Region = null;
    var parts = std.mem.splitScalar(u8, base, '_');
    while (parts.next()) |part| {
        if (is_all_upper(part) or is_all_digits(part)) {
            if (Region.parse(part)) |r| {
                region = r;
            }
        }
        if (Language.parse(part)) |l| {
            language = l;
        }
    }
    if (language == null and region == null) {
        return null;
    }
    return Locale{
        .language = language orelse .en,
        .region = region,
        .script = null,
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

fn timezone_from_env() ?Timezone {
    const tz = std.c.getenv("TZ");
    if (tz) |env_z| {
        var env = std.mem.span(env_z);
        if (env.len > 0) {
            if (env[0] == ':') {
                env = env[1..];
            }
            return Timezone.parse(env);
        }
    }
    return null;
}

fn timezone_from_etc_localtime(io: Io) ?Timezone {
    var buf: [4096]u8 = undefined;
    const len = std.Io.Dir.readLinkAbsolute(io, "/etc/localtime", &buf) catch return null;
    const symlink = buf[0..len];
    if (std.mem.indexOf(u8, symlink, "zoneinfo/")) |idx| {
        return Timezone.parse(symlink[idx + 9 ..]);
    }
    return null;
}

fn timezone_from_etc_timezone(io: Io) ?Timezone {
    const file = std.Io.Dir.openFileAbsolute(io, "/etc/timezone", .{}) catch return null;
    defer file.close(io);
    var buf: [64]u8 = undefined;
    const n = file.readPositionalAll(io, &buf, 0) catch return null;
    const contents = buf[0..n];
    if (std.mem.indexOfScalar(u8, contents, '\n')) |idx| {
        return Timezone.parse(contents[0..idx]);
    }
    return Timezone.parse(contents);
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
