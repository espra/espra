// Public Domain (-) 2026-present, The Espra Core Authors.
// See the Espra Core UNLICENSE file for details.

const builtin = @import("builtin");
const std = @import("std");
const sys = @import("sys");
const tzdata = @import("tzdata.zig");

pub const Month = tzdata.Month;
pub const Weekday = tzdata.Weekday;

pub const Day: i64 = 24 * Hour;
pub const Hour: i64 = 60 * Minute;
pub const Microsecond: i64 = 1_000;
pub const Millisecond: i64 = 1_000_000;
pub const Minute: i64 = 60 * Second;
pub const Nanosecond: i64 = 1;
pub const Second: i64 = 1_000_000_000;
pub const Week: i64 = 7 * Day;

const ns_per_sec: i64 = 1_000_000_000;
const sec_per_min: i64 = 60;
const sec_per_hour: i64 = 3_600;
const sec_per_day: i64 = 86_400;

const windows = if (sys.is_windows) struct {
    const BOOL = i32;
    const DWORD = u32;
    const FILETIME = extern struct {
        dwLowDateTime: DWORD,
        dwHighDateTime: DWORD,
    };
    const LARGE_INTEGER = extern struct {
        QuadPart: i64,
    };

    // FILETIME values are 100ns intervals since the Windows epoch, which is set
    // to Jan 1st, 1601. We use this epoch_delta to adjust it to the Unix epoch.
    const epoch_delta: u64 = 116_444_736_000_000_000;

    extern "kernel32" fn GetSystemTimePreciseAsFileTime(lpSystemTimeAsFileTime: *FILETIME) callconv(.winapi) void;
    extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *LARGE_INTEGER) callconv(.winapi) BOOL;
    extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *LARGE_INTEGER) callconv(.winapi) BOOL;
} else undefined;

var darwin_timebase_denom: u32 = 0;
var darwin_timebase_numer: u32 = 0;
var windows_qpc_frequency: u128 = 0;

pub const Adjustment = enum(u8) {
    none,
    shifted_backward,
    shifted_forward,
};

pub const DateTime = struct {
    year: i32,
    month: Month,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    nanosecond: u32,
    timezone: sys.Timezone,

    pub fn utc(self: DateTime) Instant {
        _ = self;
        return Instant{
            .adjustment = .none,
            .monotonic = 0,
            .nanoseconds = 0,
            .seconds = 0,
        };
    }

    pub fn weekday(self: DateTime) Weekday {
        return day_of_week(days_from_date(self.year, self.month, self.day));
    }
};

pub const Instant = struct {
    adjustment: Adjustment,
    monotonic: i64,
    nanoseconds: u32,
    seconds: i64,

    pub fn to(self: Instant, timezone: sys.Timezone) DateTime {
        _ = self;
        return DateTime{
            .year = 0,
            .month = .january,
            .day = 0,
            .hour = 0,
            .minute = 0,
            .second = 0,
            .nanosecond = 0,
            .timezone = timezone,
        };
    }

    pub fn sub(self: Instant, other: Instant) i64 {
        if (self.monotonic != 0 and other.monotonic != 0) {
            return self.monotonic - other.monotonic;
        }
        return (self.seconds - other.seconds) * ns_per_sec +
            @as(i64, self.nanoseconds) - @as(i64, other.nanoseconds);
    }
};

const ClockReading = struct {
    nanoseconds: u32,
    seconds: i64,
};

pub fn now() Instant {
    const wall = read_clock();
    return Instant{
        .adjustment = .none,
        .monotonic = read_monotonic_clock(),
        .nanoseconds = wall.nanoseconds,
        .seconds = wall.seconds,
    };
}

pub fn since(start: Instant) i64 {
    return now().sub(start);
}

fn day_of_week(days_since_epoch: i64) Weekday {
    return @enumFromInt(@as(u8, @intCast(@mod(days_since_epoch + 4, 7))));
}

fn days_from_date(year: i32, month: Month, day: u8) i64 {
    _ = year;
    _ = month;
    _ = day;
    return 0;
}

fn read_clock() ClockReading {
    switch (builtin.os.tag) {
        .linux, .macos, .ios => {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
            return ClockReading{
                .nanoseconds = @intCast(ts.nsec),
                .seconds = ts.sec,
            };
        },
        .windows => {
            var ft: windows.FILETIME = undefined;
            _ = windows.GetSystemTimePreciseAsFileTime(&ft);
            const ticks = @as(u64, ft.dwHighDateTime) << 32 | @as(u64, ft.dwLowDateTime);
            const ticks_since_unix = ticks - windows.epoch_delta;
            return ClockReading{
                .nanoseconds = @intCast((ticks_since_unix % 10_000_000) * 100),
                .seconds = @intCast(ticks_since_unix / 10_000_000),
            };
        },
        else => {
            @compileError("Not implemented");
        },
    }
}

fn read_monotonic_clock() i64 {
    switch (builtin.os.tag) {
        .linux => {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
            return @as(i64, ts.sec) * 1_000_000_000 + @as(i64, ts.nsec);
        },
        .macos, .ios => {
            if (darwin_timebase_denom == 0 or darwin_timebase_numer == 0) {
                var timebase: std.c.mach_timebase_info_data = undefined;
                _ = std.c.mach_timebase_info(&timebase);
                darwin_timebase_denom = timebase.denom;
                darwin_timebase_numer = timebase.numer;
            }
            const tick = std.c.mach_absolute_time();
            const ns = @as(u128, tick) * @as(u128, darwin_timebase_numer) / @as(u128, darwin_timebase_denom);
            return @intCast(ns);
        },
        .windows => {
            if (windows_qpc_frequency == 0) {
                var freq: windows.LARGE_INTEGER = undefined;
                _ = windows.QueryPerformanceFrequency(&freq);
                windows_qpc_frequency = @intCast(freq.QuadPart);
            }
            var count: windows.LARGE_INTEGER = undefined;
            _ = windows.QueryPerformanceCounter(&count);
            const ticks: u128 = @intCast(count.QuadPart);
            const ns = ticks * 1_000_000_000 / windows_qpc_frequency;
            return @intCast(ns);
        },
        else => {
            @compileError("Not implemented");
        },
    }
}
