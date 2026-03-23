// Public Domain (-) 2026-present, The Espra Core Authors.
// See the Espra Core UNLICENSE file for details.

const builtin = @import("builtin");
const std = @import("std");
const sys = @import("sys");
const xxh3 = @import("xxh3");
const tzdata = @import("tzdata.zig");

pub const ParseError = error{
    InvalidDuration,
    InvalidRFC3339,
};

pub const Month = tzdata.Month;
pub const Weekday = tzdata.Weekday;
pub const Timezone = sys.Timezone;

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
var windows_qpc_frequency: u64 = 0;

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

    pub fn format(self: DateTime, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [35]u8 = undefined;
        if (self.rfc3339(&buf)) |s| {
            try writer.writeAll(s);
        } else {
            try writer.print("<invalid year: {d}>", .{self.year});
        }
    }

    pub fn rfc3339(self: DateTime, buf: *[35]u8) ?[]const u8 {
        if (self.year < 0 or self.year > 9999) {
            return null;
        }
        return buf[0..write_rfc3339(buf, self)];
    }

    pub fn utc(self: DateTime) Instant {
        const seconds_since_epoch = unix_seconds(self);
        if (self.timezone == .UTC) {
            return .{
                .adjustment = .none,
                .monotonic = 0,
                .nanoseconds = self.nanosecond,
                .seconds = seconds_since_epoch,
            };
        }
        const rule = tzdata.get_rule(self.timezone);
        if (rule.dst == null) {
            return .{
                .adjustment = .none,
                .monotonic = 0,
                .nanoseconds = self.nanosecond,
                .seconds = seconds_since_epoch - rule.std_offset,
            };
        }
        const dst_offset = switch (rule.dst.?) {
            .oscillating => |transitions| if (transitions[0].offset != 0) transitions[0].offset else transitions[1].offset,
            .continuous => |entries| blk: {
                for (entries) |entry| {
                    if (entry.offset != 0) break :blk entry.offset;
                }
                break :blk 0;
            },
        };
        // Try to find a self-consistent UTC time by trying both possible cases,
        // i.e. when the DST offset is applied and not applied.
        const offset_a = total_utc_offset(rule, seconds_since_epoch - rule.std_offset);
        const utc_a = seconds_since_epoch - offset_a;
        const ok_a = total_utc_offset(rule, utc_a) == offset_a;

        const offset_b = total_utc_offset(rule, seconds_since_epoch - rule.std_offset - dst_offset);
        const utc_b = seconds_since_epoch - offset_b;
        const ok_b = total_utc_offset(rule, utc_b) == offset_b;

        if (ok_a and ok_b) {
            // Both cases are consistent, so no shift is needed.
            if (utc_a == utc_b) {
                return .{
                    .adjustment = .none,
                    .monotonic = 0,
                    .nanoseconds = self.nanosecond,
                    .seconds = utc_a,
                };
            }
            // We have overlapping UTC times both of which could be valid. So we
            // pick the earlier one.
            return .{
                .adjustment = .shifted_backward,
                .monotonic = 0,
                .nanoseconds = self.nanosecond,
                .seconds = @min(utc_a, utc_b),
            };
        }
        // Shift forward as the earlier time doesn't exist due to a jump.
        if (!ok_a and !ok_b) {
            return .{
                .adjustment = .shifted_forward,
                .monotonic = 0,
                .nanoseconds = self.nanosecond,
                .seconds = @max(utc_a, utc_b),
            };
        }
        // We have a single unambiguous UTC time.
        return .{
            .adjustment = .none,
            .monotonic = 0,
            .nanoseconds = self.nanosecond,
            .seconds = if (ok_a) utc_a else utc_b,
        };
    }

    pub fn weekday(self: DateTime) Weekday {
        return DaysSinceEpoch.from_date(self.year, self.month, self.day).weekday();
    }
};

pub const Instant = struct {
    adjustment: Adjustment,
    monotonic: i64,
    nanoseconds: u32,
    seconds: i64,

    // TODO(tav): We may want to add overflow protection here.
    pub fn add(self: Instant, nanoseconds: i64) Instant {
        const ns = @as(i128, self.seconds) * ns_per_sec + self.nanoseconds + nanoseconds;
        return Instant{
            .adjustment = .none,
            .monotonic = if (self.monotonic != 0) self.monotonic + nanoseconds else 0,
            .nanoseconds = @intCast(@mod(ns, ns_per_sec)),
            .seconds = @intCast(@divFloor(ns, ns_per_sec)),
        };
    }

    pub fn after(self: Instant, other: Instant) bool {
        return self.seconds > other.seconds or (self.seconds == other.seconds and self.nanoseconds > other.nanoseconds);
    }

    pub fn before(self: Instant, other: Instant) bool {
        return self.seconds < other.seconds or (self.seconds == other.seconds and self.nanoseconds < other.nanoseconds);
    }

    pub fn datetime(self: Instant) DateTime {
        return datetime_from(self.seconds, self.nanoseconds, .UTC);
    }

    pub fn equal(self: Instant, other: Instant) bool {
        return self.seconds == other.seconds and self.nanoseconds == other.nanoseconds;
    }

    pub fn to(self: Instant, timezone: sys.Timezone) DateTime {
        if (timezone == .UTC) {
            return datetime_from(self.seconds, self.nanoseconds, timezone);
        }
        const rule = tzdata.get_rule(timezone);
        const offset = total_utc_offset(rule, self.seconds);
        return datetime_from(self.seconds + offset, self.nanoseconds, timezone);
    }

    pub fn sub(self: Instant, other: Instant) i64 {
        if (self.monotonic != 0 and other.monotonic != 0) {
            return self.monotonic - other.monotonic;
        }
        return (self.seconds - other.seconds) * ns_per_sec +
            @as(i64, self.nanoseconds) - @as(i64, other.nanoseconds);
    }

    pub fn utc_offset(self: Instant, timezone: sys.Timezone) i32 {
        if (timezone == .UTC) {
            return 0;
        }
        const rule = tzdata.get_rule(timezone);
        return total_utc_offset(rule, self.seconds);
    }

    pub fn unix_milliseconds(self: Instant) i64 {
        return self.seconds * 1000 + @divFloor(self.nanoseconds, 1_000_000);
    }

    pub fn unix_nanoseconds(self: Instant) i128 {
        return @as(i128, self.seconds) * ns_per_sec + self.nanoseconds;
    }
};

const ClockReading = struct {
    nanoseconds: u32,
    seconds: i64,
};

const DaysSinceEpoch = struct {
    days: i64,

    // Adapted from https://howardhinnant.github.io/date_algorithms.html#days_from_civil
    fn from_date(year: i32, month: Month, day: u8) DaysSinceEpoch {
        const m = @as(i64, @intFromEnum(month));
        const y = if (m <= 2)
            @as(i64, year) - 1
        else
            @as(i64, year);
        const era = @divFloor(y, 400);
        const era_year = y - era * 400;
        const year_day = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + @as(i64, day) - 1;
        const era_day = era_year * 365 + @divFloor(era_year, 4) - @divFloor(era_year, 100) + year_day;
        return .{
            .days = era * 146097 + era_day - 719468,
        };
    }

    fn weekday(self: DaysSinceEpoch) Weekday {
        return @enumFromInt(@as(u8, @intCast(@mod(self.days + 4, 7))));
    }
};

const TransitionPoint = struct {
    offset: i32,
    point: i64,
};

pub fn from_unix(seconds: i64, nanoseconds: u32) Instant {
    return Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = nanoseconds,
        .seconds = seconds,
    };
}

pub fn from_unix_milliseconds(ms: i64) Instant {
    return Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = @intCast(@mod(ms, 1_000) * 1_000_000),
        .seconds = @divFloor(ms, 1_000),
    };
}

pub fn from_unix_nanoseconds(ns: i128) Instant {
    return Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = @intCast(@mod(ns, ns_per_sec)),
        .seconds = @intCast(@divFloor(ns, ns_per_sec)),
    };
}

pub fn now() Instant {
    const wall = read_clock();
    return Instant{
        .adjustment = .none,
        .monotonic = read_monotonic_clock(),
        .nanoseconds = wall.nanoseconds,
        .seconds = wall.seconds,
    };
}

// TODO(tav): We may want to add overflow protection here.
pub fn parse_duration(buf: []const u8) ParseError!i64 {
    if (buf.len == 0) {
        return error.InvalidDuration;
    }
    var pos: usize = 0;
    var sign: i64 = 1;
    var total: i64 = 0;
    if (buf[0] == '-') {
        sign = -1;
        pos = 1;
    } else if (buf[0] == '+') {
        pos = 1;
    }
    if (buf.len == pos) {
        return error.InvalidDuration;
    }
    while (pos < buf.len) {
        var digits: usize = 0;
        var value: i64 = 0;
        while (pos < buf.len and buf[pos] >= '0' and buf[pos] <= '9') {
            value = value * 10 + @as(i64, buf[pos] - '0');
            digits += 1;
            pos += 1;
        }
        if (digits == 0 or digits > 19) {
            return error.InvalidDuration;
        }
        if (buf.len == pos) {
            return error.InvalidDuration;
        }
        const unit: i64 = if (buf[pos] == 's') blk: {
            pos += 1;
            break :blk Second;
        } else if (pos + 1 < buf.len and buf[pos] == 'm' and buf[pos + 1] == 's') blk: {
            pos += 2;
            break :blk Millisecond;
        } else if (buf[pos] == 'm') blk: {
            pos += 1;
            break :blk Minute;
        } else if (buf[pos] == 'h') blk: {
            pos += 1;
            break :blk Hour;
        } else if (pos + 1 < buf.len and buf[pos] == 'u' and buf[pos + 1] == 's') blk: {
            pos += 2;
            break :blk Microsecond;
        } else if (pos + 1 < buf.len and buf[pos] == 'n' and buf[pos + 1] == 's') blk: {
            pos += 2;
            break :blk Nanosecond;
        } else {
            return error.InvalidDuration;
        };
        total += value * unit;
    }
    return total * sign;
}

pub fn parse_rfc3339(buf: []const u8) ParseError!Instant {
    // NOTE(tav): We support RFC 3339 timestamps without the trailing Z or
    // timezone offset, i.e. "2025-01-01T00:00:00".
    if (buf.len < 19) {
        return error.InvalidRFC3339;
    }
    const year = parse_digits(buf, 0, 4) orelse return error.InvalidRFC3339;
    if (buf[4] != '-') {
        return error.InvalidRFC3339;
    }
    const month = parse_digits(buf, 5, 2) orelse return error.InvalidRFC3339;
    if (month < 1 or month > 12) {
        return error.InvalidRFC3339;
    }
    const month_enum: Month = @enumFromInt(month);
    if (buf[7] != '-') {
        return error.InvalidRFC3339;
    }
    const day = parse_digits(buf, 8, 2) orelse return error.InvalidRFC3339;
    if (day < 1 or day > days_in_month(month_enum, year)) {
        return error.InvalidRFC3339;
    }
    if (buf[10] != 'T' and buf[10] != 't') {
        return error.InvalidRFC3339;
    }
    const hour = parse_digits(buf, 11, 2) orelse return error.InvalidRFC3339;
    if (hour < 0 or hour > 23) {
        return error.InvalidRFC3339;
    }
    if (buf[13] != ':') {
        return error.InvalidRFC3339;
    }
    const minute = parse_digits(buf, 14, 2) orelse return error.InvalidRFC3339;
    if (minute < 0 or minute > 59) {
        return error.InvalidRFC3339;
    }
    if (buf[16] != ':') {
        return error.InvalidRFC3339;
    }
    const second = parse_digits(buf, 17, 2) orelse return error.InvalidRFC3339;
    // RFC 3339 allows seconds to be 60 to account for leap seconds.
    if (second < 0 or second > 60) {
        return error.InvalidRFC3339;
    }
    var nanosecond: u32 = 0;
    var pos: usize = 19;
    if (buf.len > 19 and buf[19] == '.') {
        pos = 20;
        var digits: usize = 0;
        while (pos < buf.len and buf[pos] >= '0' and buf[pos] <= '9') {
            // We truncate everything after the 9th digit to avoid overflowing
            // the nanoseconds field.
            if (digits < 9) {
                nanosecond = nanosecond * 10 + @as(u32, buf[pos] - '0');
                digits += 1;
            }
            pos += 1;
        }
        while (digits < 9) {
            nanosecond *= 10;
            digits += 1;
        }
    }
    var offset: i64 = 0;
    if (buf.len > pos) {
        if (buf[pos] == 'Z' or buf[pos] == 'z') {
            pos += 1;
        } else if (buf[pos] == '+' or buf[pos] == '-') {
            const factor: i64 = if (buf[pos] == '+') 1 else -1;
            pos += 1;
            const tz_hour = parse_digits(buf, pos, 2) orelse return error.InvalidRFC3339;
            if (tz_hour < 0 or tz_hour > 23) {
                return error.InvalidRFC3339;
            }
            pos += 2;
            if (buf[pos] != ':') {
                return error.InvalidRFC3339;
            }
            pos += 1;
            const tz_minute = parse_digits(buf, pos, 2) orelse return error.InvalidRFC3339;
            if (tz_minute < 0 or tz_minute > 59) {
                return error.InvalidRFC3339;
            }
            pos += 2;
            offset = factor * (@as(i64, tz_hour) * sec_per_hour + @as(i64, tz_minute) * sec_per_min);
        }
    }
    if (pos != buf.len) {
        return error.InvalidRFC3339;
    }
    return Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = nanosecond,
        .seconds = DaysSinceEpoch.from_date(year, month_enum, @intCast(day)).days * sec_per_day +
            @as(i64, hour) * sec_per_hour +
            @as(i64, minute) * sec_per_min +
            @as(i64, second) - offset,
    };
}

pub fn since(start: Instant) i64 {
    return now().sub(start);
}

pub fn rule_hash(timezone: sys.Timezone, year: i32) u64 {
    var buf: [512]u8 = undefined;
    const rule = tzdata.get_rule(timezone);
    @memcpy(buf[0..][0..4], std.mem.asBytes(&rule.std_offset));
    const dst = rule.dst orelse return xxh3.hash64(buf[0..4]);
    switch (dst) {
        .continuous => |entries| {
            var pos: usize = 4;
            // NOTE(tav): The stack buffer could overflow if we end up
            // generating a rule with lots of entries.
            for (entries) |entry| {
                const start_year: i32 = @intCast(entry.start_year);
                const end_year: i32 = if (entry.end_year) |ey| @intCast(ey) else year;
                if (year >= start_year and year <= end_year) {
                    const bytes = std.mem.asBytes(&entry);
                    @memcpy(buf[pos..][0..bytes.len], bytes);
                    pos += bytes.len;
                }
            }
            return xxh3.hash64(buf[0..pos]);
        },
        .oscillating => |transitions| {
            const bytes = std.mem.asBytes(&transitions);
            @memcpy(buf[4..][0..bytes.len], bytes);
            return xxh3.hash64(buf[0 .. bytes.len + 4]);
        },
    }
}

pub fn until(end: Instant) i64 {
    return end.sub(now());
}

fn offset_continuous(std_offset: i32, entries: []const tzdata.ContinuousDST, seconds_since_epoch: i64) i32 {
    const max_transitions = 128;
    const year = year_from(seconds_since_epoch + std_offset);
    // When collecting the transitions for the previous and current year, we
    // correct for the std_offset here as ContinuousDST transitions are always
    // in wall time.
    var transitions: [max_transitions]TransitionPoint = undefined;
    var count: usize = 0;
    for ([_]i32{ year - 1, year }) |y| {
        for (entries) |entry| {
            const start_year: i32 = @intCast(entry.start_year);
            const end_year: i32 = if (entry.end_year) |ey| @intCast(ey) else y;
            if (y >= start_year and y <= end_year and count < max_transitions) {
                const day = resolve_day(entry.day, entry.month, y);
                transitions[count] = .{
                    .offset = entry.offset,
                    .point = DaysSinceEpoch.from_date(y, entry.month, day).days * sec_per_day +
                        entry.transition_time - std_offset,
                };
                count += 1;
            }
        }
    }
    if (count > 1) {
        for (1..count) |idx| {
            const transition = transitions[idx];
            var j = idx;
            while (j > 0 and transitions[j - 1].point > transition.point) {
                transitions[j] = transitions[j - 1];
                j -= 1;
            }
            transitions[j] = transition;
        }
    }
    // Do a second pass that corrects the wall-time transitions by subtracting
    // the DST offset that was in effect before each transition.
    var current_dst: i32 = 0;
    var final_offset: i32 = 0;
    for (transitions[0..count]) |*transition| {
        transition.point -= current_dst;
        if (transition.point <= seconds_since_epoch) {
            final_offset = transition.offset;
        }
        current_dst = transition.offset;
    }
    return std_offset + final_offset;
}

// Adapted from https://howardhinnant.github.io/date_algorithms.html#civil_from_days
fn datetime_from(seconds_since_epoch: i64, nanoseconds: u32, timezone: Timezone) DateTime {
    const days = @divFloor(seconds_since_epoch, sec_per_day);
    const seconds = @mod(seconds_since_epoch, sec_per_day);
    const adjusted = days + 719468;
    const era = @divFloor(adjusted, 146097);
    const era_day = adjusted - era * 146097;
    const era_year = @divFloor(
        era_day - @divFloor(era_day, 1460) + @divFloor(era_day, 36524) - @divFloor(era_day, 146096),
        365,
    );
    const year_day = era_day - (365 * era_year + @divFloor(era_year, 4) - @divFloor(era_year, 100));
    const month_number = @divFloor(5 * year_day + 2, 153);
    const month: u8 = @intCast(if (month_number < 10) month_number + 3 else month_number - 9);
    return DateTime{
        .year = @intCast(if (month <= 2) era_year + era * 400 + 1 else era_year + era * 400),
        .month = @enumFromInt(month),
        .day = @intCast(year_day - @divFloor(153 * month_number + 2, 5) + 1),
        .hour = @intCast(@divFloor(seconds, sec_per_hour)),
        .minute = @intCast(@divFloor(@mod(seconds, sec_per_hour), sec_per_min)),
        .second = @intCast(@mod(seconds, sec_per_min)),
        .nanosecond = nanoseconds,
        .timezone = timezone,
    };
}

fn days_in_month(month: Month, year: i32) u8 {
    const table = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month != .february or !is_leap_year(year)) {
        return table[@intFromEnum(month) - 1];
    }
    return 29;
}

fn is_leap_year(year: i32) bool {
    return @mod(year, 4) == 0 and ((@mod(year, 100) != 0) or @mod(year, 400) == 0);
}

fn oscillating_offset(std_offset: i32, transitions: [2]tzdata.OscillatingDST, seconds_since_epoch: i64) i32 {
    const year = year_from(seconds_since_epoch + std_offset);
    const point_0 = transition_point(transitions[0], year, std_offset, transitions[1].offset);
    const point_1 = transition_point(transitions[1], year, std_offset, transitions[0].offset);
    if (point_0 < point_1) {
        if (seconds_since_epoch >= point_0 and seconds_since_epoch < point_1) {
            return std_offset + transitions[0].offset;
        }
        return std_offset + transitions[1].offset;
    }
    if (seconds_since_epoch >= point_1 and seconds_since_epoch < point_0) {
        return std_offset + transitions[1].offset;
    }
    return std_offset + transitions[0].offset;
}

fn parse_digits(buf: []const u8, start: usize, width: usize) ?i32 {
    if (start + width > buf.len) {
        return null;
    }
    var value: i32 = 0;
    for (buf[start .. start + width]) |c| {
        if (c < '0' or c > '9') {
            return null;
        }
        value = value * 10 + @as(i32, c - '0');
    }
    return value;
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
            // NOTE(tav): This is thread-safe. Worst case, we'll end up calling
            // mach_timebase_info() multiple times.
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
            // NOTE(tav): Same as for macOS. The only difference is that we
            // assume that the frequency will fit inside a u64 which is true for
            // now.
            if (windows_qpc_frequency == 0) {
                var freq: windows.LARGE_INTEGER = undefined;
                _ = windows.QueryPerformanceFrequency(&freq);
                windows_qpc_frequency = @intCast(freq.QuadPart);
            }
            var count: windows.LARGE_INTEGER = undefined;
            _ = windows.QueryPerformanceCounter(&count);
            const ticks: u128 = @intCast(count.QuadPart);
            const ns = ticks * 1_000_000_000 / @as(u128, windows_qpc_frequency);
            return @intCast(ns);
        },
        else => {
            @compileError("Not implemented");
        },
    }
}

fn resolve_day(spec: tzdata.DaySpec, month: Month, year: i32) u8 {
    return switch (spec) {
        .specific_day => |day| day,
        .at_or_after => |s| {
            const start = DaysSinceEpoch.from_date(year, month, s.day).weekday();
            const diff: u8 = @intCast(@mod(
                @as(i8, @intCast(@intFromEnum(s.weekday))) - @as(i8, @intCast(@intFromEnum(start))),
                7,
            ));
            return s.day + diff;
        },
        .last_weekday_of_month => |target_weekday| {
            const days = days_in_month(month, year);
            const last_day = DaysSinceEpoch.from_date(year, month, days).weekday();
            const diff: u8 = @intCast(@mod(
                @as(i8, @intCast(@intFromEnum(last_day))) - @as(i8, @intCast(@intFromEnum(target_weekday))),
                7,
            ));
            return days - diff;
        },
        .at_or_before => |s| {
            const end = DaysSinceEpoch.from_date(year, month, s.day).weekday();
            const diff: u8 = @intCast(@mod(
                @as(i8, @intCast(@intFromEnum(end))) - @as(i8, @intCast(@intFromEnum(s.weekday))),
                7,
            ));
            return s.day - diff;
        },
    };
}

fn total_utc_offset(rule: tzdata.TimezoneRule, seconds_since_epoch: i64) i32 {
    const dst = rule.dst orelse return rule.std_offset;
    return switch (dst) {
        .oscillating => |transitions| oscillating_offset(rule.std_offset, transitions, seconds_since_epoch),
        .continuous => |entries| offset_continuous(rule.std_offset, entries, seconds_since_epoch),
    };
}

// Find the point in Unix seconds at which the oscillating transition fires in
// the given year.
fn transition_point(transition: tzdata.OscillatingDST, year: i32, std_offset: i32, prev_offset: i32) i64 {
    const day = resolve_day(transition.day, transition.month, year);
    var point = DaysSinceEpoch.from_date(year, transition.month, day).days * sec_per_day + transition.transition_time;
    switch (transition.transition_in) {
        .wall_time => point -= std_offset + prev_offset,
        .utc => {},
        .standard_time => point -= std_offset,
    }
    return point;
}

fn unix_seconds(dt: DateTime) i64 {
    return DaysSinceEpoch.from_date(dt.year, dt.month, dt.day).days * sec_per_day +
        @as(i64, dt.hour) * sec_per_hour +
        @as(i64, dt.minute) * sec_per_min +
        @as(i64, dt.second);
}

fn write_rfc3339(buf: *[35]u8, dt: DateTime) usize {
    var pos: usize = 0;
    pos = write_padded(buf, pos, dt.year, 4);
    buf[pos] = '-';
    pos += 1;
    pos = write_padded(buf, pos, @intFromEnum(dt.month), 2);
    buf[pos] = '-';
    pos += 1;
    pos = write_padded(buf, pos, dt.day, 2);
    buf[pos] = 'T';
    pos += 1;
    pos = write_padded(buf, pos, dt.hour, 2);
    buf[pos] = ':';
    pos += 1;
    pos = write_padded(buf, pos, dt.minute, 2);
    buf[pos] = ':';
    pos += 1;
    pos = write_padded(buf, pos, dt.second, 2);
    if (dt.nanosecond != 0) {
        buf[pos] = '.';
        pos += 1;
        pos = write_padded(buf, pos, dt.nanosecond, 9);
        while (pos > 0 and buf[pos - 1] == '0') {
            pos -= 1;
        }
    }
    if (dt.timezone == .UTC) {
        buf[pos] = 'Z';
        pos += 1;
        return pos;
    }
    const rule = tzdata.get_rule(dt.timezone);
    var offset = total_utc_offset(rule, unix_seconds(dt) - rule.std_offset);
    if (offset < 0) {
        buf[pos] = '-';
        offset = -offset;
    } else {
        buf[pos] = '+';
    }
    pos += 1;
    pos = write_padded(buf, pos, @divFloor(offset, 3600), 2);
    buf[pos] = ':';
    pos += 1;
    pos = write_padded(buf, pos, @divFloor(@mod(offset, 3600), 60), 2);
    return pos;
}

fn write_padded(buf: *[35]u8, start: usize, value: anytype, width: usize) usize {
    var v: u64 = @intCast(value);
    var i = width;
    while (i > 0) {
        i -= 1;
        buf[start + i] = @intCast('0' + v % 10);
        v /= 10;
    }
    return start + width;
}

// Adapted from https://howardhinnant.github.io/date_algorithms.html#civil_from_days
fn year_from(seconds_since_epoch: i64) i32 {
    const days = @divFloor(seconds_since_epoch, sec_per_day);
    const adjusted = days + 719468;
    const era = @divFloor(adjusted, 146097);
    const era_day = adjusted - era * 146097;
    const era_year = @divFloor(
        era_day - @divFloor(era_day, 1460) + @divFloor(era_day, 36524) - @divFloor(era_day, 146096),
        365,
    );
    const year_day = era_day - (365 * era_year + @divFloor(era_year, 4) - @divFloor(era_year, 100));
    const month_number = @divFloor(5 * year_day + 2, 153);
    const month: u8 = @intCast(if (month_number < 10) month_number + 3 else month_number - 9);
    return @intCast(if (month <= 2) era_year + era * 400 + 1 else era_year + era * 400);
}

const testing = std.testing;

test "epoch zero is 1970-01-01 00:00:00 UTC" {
    const dt = datetime_from(0, 0, .UTC);
    try testing.expectEqual(@as(i32, 1970), dt.year);
    try testing.expectEqual(Month.january, dt.month);
    try testing.expectEqual(@as(u8, 1), dt.day);
    try testing.expectEqual(@as(u8, 0), dt.hour);
    try testing.expectEqual(@as(u8, 0), dt.minute);
    try testing.expectEqual(@as(u8, 0), dt.second);
}

test "known date 2000-03-01" {
    // 2000-03-01 00:00:00 UTC = 951868800
    const dt = datetime_from(951868800, 0, .UTC);
    try testing.expectEqual(@as(i32, 2000), dt.year);
    try testing.expectEqual(Month.march, dt.month);
    try testing.expectEqual(@as(u8, 1), dt.day);
}

test "round-trip date to epoch and back" {
    const dt = DateTime{
        .year = 2025,
        .month = .july,
        .day = 15,
        .hour = 13,
        .minute = 45,
        .second = 30,
        .nanosecond = 0,
        .timezone = .UTC,
    };
    const secs = unix_seconds(dt);
    const back = datetime_from(secs, 0, .UTC);
    try testing.expectEqual(dt.year, back.year);
    try testing.expectEqual(dt.month, back.month);
    try testing.expectEqual(dt.day, back.day);
    try testing.expectEqual(dt.hour, back.hour);
    try testing.expectEqual(dt.minute, back.minute);
    try testing.expectEqual(dt.second, back.second);
}

test "negative epoch 1969-12-31 23:59:59" {
    const dt = datetime_from(-1, 0, .UTC);
    try testing.expectEqual(@as(i32, 1969), dt.year);
    try testing.expectEqual(Month.december, dt.month);
    try testing.expectEqual(@as(u8, 31), dt.day);
    try testing.expectEqual(@as(u8, 23), dt.hour);
    try testing.expectEqual(@as(u8, 59), dt.minute);
    try testing.expectEqual(@as(u8, 59), dt.second);
}

test "leap day 2024-02-29" {
    const dt = DateTime{
        .year = 2024,
        .month = .february,
        .day = 29,
        .hour = 12,
        .minute = 0,
        .second = 0,
        .nanosecond = 0,
        .timezone = .UTC,
    };
    const secs = unix_seconds(dt);
    const back = datetime_from(secs, 0, .UTC);
    try testing.expectEqual(@as(u8, 29), back.day);
    try testing.expectEqual(Month.february, back.month);
    try testing.expectEqual(@as(i32, 2024), back.year);
}

test "epoch weekday is Thursday" {
    const dt = datetime_from(0, 0, .UTC);
    try testing.expectEqual(Weekday.thursday, dt.weekday());
}

test "2025-03-21 is Friday" {
    const dt = DateTime{
        .year = 2025,
        .month = .march,
        .day = 21,
        .hour = 0,
        .minute = 0,
        .second = 0,
        .nanosecond = 0,
        .timezone = .UTC,
    };
    try testing.expectEqual(Weekday.friday, dt.weekday());
}

test "leap years" {
    try testing.expect(is_leap_year(2000));
    try testing.expect(is_leap_year(2024));
    try testing.expect(!is_leap_year(1900));
    try testing.expect(!is_leap_year(2023));
    try testing.expect(is_leap_year(2400));
}

test "days in month" {
    try testing.expectEqual(@as(u8, 31), days_in_month(.january, 2025));
    try testing.expectEqual(@as(u8, 28), days_in_month(.february, 2025));
    try testing.expectEqual(@as(u8, 29), days_in_month(.february, 2024));
    try testing.expectEqual(@as(u8, 30), days_in_month(.april, 2025));
}

test "resolve specific day" {
    const spec = tzdata.DaySpec{ .specific_day = 15 };
    try testing.expectEqual(@as(u8, 15), resolve_day(spec, .march, 2025));
}

test "resolve last Sunday of March 2025" {
    // March 2025: last day is 31st (Monday), last Sunday is 30th.
    const spec = tzdata.DaySpec{ .last_weekday_of_month = .sunday };
    try testing.expectEqual(@as(u8, 30), resolve_day(spec, .march, 2025));
}

test "resolve last Sunday of October 2025" {
    // October 2025: last day is 31st (Friday), last Sunday is 26th.
    const spec = tzdata.DaySpec{ .last_weekday_of_month = .sunday };
    try testing.expectEqual(@as(u8, 26), resolve_day(spec, .october, 2025));
}

test "resolve Friday >= 8 in March 2025" {
    // March 8 2025 is Saturday, so first Friday on or after 8th is 14th.
    const spec = tzdata.DaySpec{ .at_or_after = .{ .weekday = .friday, .day = 8 } };
    try testing.expectEqual(@as(u8, 14), resolve_day(spec, .march, 2025));
}

test "resolve Saturday <= 30 in October 2025" {
    // October 30 2025 is Thursday, so last Saturday on or before 30th is 25th.
    const spec = tzdata.DaySpec{ .at_or_before = .{ .weekday = .saturday, .day = 30 } };
    try testing.expectEqual(@as(u8, 25), resolve_day(spec, .october, 2025));
}

test "UTC to New York EST" {
    // 2025-01-15 12:00:00 UTC = 2025-01-15 07:00:00 EST (UTC-5)
    const instant = Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = 0,
        .seconds = 1736942400, // 2025-01-15 12:00:00 UTC
    };
    const dt = instant.to(.@"America/New_York");
    try testing.expectEqual(@as(u8, 7), dt.hour);
    try testing.expectEqual(@as(u8, 15), dt.day);
}

test "UTC to New York EDT" {
    // 2025-07-15 12:00:00 UTC = 2025-07-15 08:00:00 EDT (UTC-4)
    const instant = Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = 0,
        .seconds = 1752580800, // 2025-07-15 12:00:00 UTC
    };
    const dt = instant.to(.@"America/New_York");
    try testing.expectEqual(@as(u8, 8), dt.hour);
    try testing.expectEqual(@as(u8, 15), dt.day);
}

test "UTC to Sydney AEDT" {
    // 2025-01-15 12:00:00 UTC = 2025-01-15 23:00:00 AEDT (UTC+11)
    const instant = Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = 0,
        .seconds = 1736942400,
    };
    const dt = instant.to(.@"Australia/Sydney");
    try testing.expectEqual(@as(u8, 23), dt.hour);
    try testing.expectEqual(@as(u8, 15), dt.day);
}

test "UTC to Sydney AEST" {
    // 2025-07-15 12:00:00 UTC = 2025-07-15 22:00:00 AEST (UTC+10)
    const instant = Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = 0,
        .seconds = 1752580800,
    };
    const dt = instant.to(.@"Australia/Sydney");
    try testing.expectEqual(@as(u8, 22), dt.hour);
    try testing.expectEqual(@as(u8, 15), dt.day);
}

test "UTC to Dublin IST summer" {
    // 2025-07-15 12:00:00 UTC = 2025-07-15 13:00:00 IST (UTC+1)
    // Ireland uses negative DST: standard is IST (+1), winter goes to GMT (0)
    const instant = Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = 0,
        .seconds = 1752580800,
    };
    const dt = instant.to(.@"Europe/Dublin");
    try testing.expectEqual(@as(u8, 13), dt.hour);
}

test "UTC to Dublin GMT winter" {
    // 2025-01-15 12:00:00 UTC = 2025-01-15 12:00:00 GMT (UTC+0)
    const instant = Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = 0,
        .seconds = 1736942400,
    };
    const dt = instant.to(.@"Europe/Dublin");
    try testing.expectEqual(@as(u8, 12), dt.hour);
}

test "New York EST to UTC" {
    const dt = DateTime{
        .year = 2025,
        .month = .january,
        .day = 15,
        .hour = 7,
        .minute = 0,
        .second = 0,
        .nanosecond = 0,
        .timezone = .@"America/New_York",
    };
    const instant = dt.utc();
    try testing.expectEqual(Adjustment.none, instant.adjustment);
    try testing.expectEqual(@as(i64, 1736942400), instant.seconds);
}

test "New York EDT to UTC" {
    const dt = DateTime{
        .year = 2025,
        .month = .july,
        .day = 15,
        .hour = 8,
        .minute = 0,
        .second = 0,
        .nanosecond = 0,
        .timezone = .@"America/New_York",
    };
    const instant = dt.utc();
    try testing.expectEqual(Adjustment.none, instant.adjustment);
    try testing.expectEqual(@as(i64, 1752580800), instant.seconds);
}

test "New York spring forward gap" {
    // 2025-03-09 02:30:00 ET doesn't exist (clocks jump 2:00 -> 3:00)
    // Should shift forward to 03:30 EDT = 07:30 UTC
    const dt = DateTime{
        .year = 2025,
        .month = .march,
        .day = 9,
        .hour = 2,
        .minute = 30,
        .second = 0,
        .nanosecond = 0,
        .timezone = .@"America/New_York",
    };
    const instant = dt.utc();
    try testing.expectEqual(Adjustment.shifted_forward, instant.adjustment);
    // 2025-03-09 07:30:00 UTC
    const check = instant.to(.@"America/New_York");
    try testing.expectEqual(@as(u8, 3), check.hour);
    try testing.expectEqual(@as(u8, 30), check.minute);
}

test "New York fall back overlap" {
    // 2025-11-02 01:30:00 ET is ambiguous (clocks fall back 2:00 -> 1:00)
    // Should pick earlier occurrence (EDT, UTC-4) -> 05:30 UTC
    const dt = DateTime{
        .year = 2025,
        .month = .november,
        .day = 2,
        .hour = 1,
        .minute = 30,
        .second = 0,
        .nanosecond = 0,
        .timezone = .@"America/New_York",
    };
    const instant = dt.utc();
    try testing.expectEqual(Adjustment.shifted_backward, instant.adjustment);
    // Earlier occurrence: 1:30 AM EDT = 05:30 UTC
    const check = instant.to(.@"America/New_York");
    try testing.expectEqual(@as(u8, 1), check.hour);
    try testing.expectEqual(@as(u8, 30), check.minute);
}

test "round-trip UTC through New York in winter" {
    const original = Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = 123,
        .seconds = 1736942400,
    };
    const dt = original.to(.@"America/New_York");
    const back = dt.utc();
    try testing.expectEqual(original.seconds, back.seconds);
    try testing.expectEqual(original.nanoseconds, back.nanoseconds);
    try testing.expectEqual(Adjustment.none, back.adjustment);
}

test "round-trip UTC through New York in summer" {
    const original = Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = 456,
        .seconds = 1752580800,
    };
    const dt = original.to(.@"America/New_York");
    const back = dt.utc();
    try testing.expectEqual(original.seconds, back.seconds);
    try testing.expectEqual(original.nanoseconds, back.nanoseconds);
    try testing.expectEqual(Adjustment.none, back.adjustment);
}

test "round-trip UTC through Sydney in summer" {
    const original = Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = 0,
        .seconds = 1736942400,
    };
    const dt = original.to(.@"Australia/Sydney");
    const back = dt.utc();
    try testing.expectEqual(original.seconds, back.seconds);
    try testing.expectEqual(Adjustment.none, back.adjustment);
}

test "round-trip UTC through Dublin in summer" {
    const original = Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = 0,
        .seconds = 1752580800,
    };
    const dt = original.to(.@"Europe/Dublin");
    const back = dt.utc();
    try testing.expectEqual(original.seconds, back.seconds);
    try testing.expectEqual(Adjustment.none, back.adjustment);
}

test "round-trip UTC through Dublin in winter" {
    const original = Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = 0,
        .seconds = 1736942400,
    };
    const dt = original.to(.@"Europe/Dublin");
    const back = dt.utc();
    try testing.expectEqual(original.seconds, back.seconds);
    try testing.expectEqual(Adjustment.none, back.adjustment);
}

test "Dublin spring forward gap" {
    // Ireland: clocks go from GMT (UTC+0) to IST (UTC+1) on last Sunday of March.
    // 2025-03-30 01:30:00 doesn't exist (clocks jump 1:00 -> 2:00).
    const dt = DateTime{
        .year = 2025,
        .month = .march,
        .day = 30,
        .hour = 1,
        .minute = 30,
        .second = 0,
        .nanosecond = 0,
        .timezone = .@"Europe/Dublin",
    };
    const instant = dt.utc();
    try testing.expectEqual(Adjustment.shifted_forward, instant.adjustment);
    const check = instant.to(.@"Europe/Dublin");
    try testing.expectEqual(@as(u8, 2), check.hour);
    try testing.expectEqual(@as(u8, 30), check.minute);
}

test "Dublin fall back overlap" {
    // Ireland: clocks go from IST (UTC+1) to GMT (UTC+0) on last Sunday of October.
    // 2025-10-26 01:30:00 is ambiguous (clocks fall back 2:00 -> 1:00).
    // Should pick earlier occurrence (IST, UTC+1) -> 00:30 UTC.
    const dt = DateTime{
        .year = 2025,
        .month = .october,
        .day = 26,
        .hour = 1,
        .minute = 30,
        .second = 0,
        .nanosecond = 0,
        .timezone = .@"Europe/Dublin",
    };
    const instant = dt.utc();
    try testing.expectEqual(Adjustment.shifted_backward, instant.adjustment);
    const check = instant.to(.@"Europe/Dublin");
    try testing.expectEqual(@as(u8, 1), check.hour);
    try testing.expectEqual(@as(u8, 30), check.minute);
}

test "UTC to Casablanca winter (Morocco continuous DST)" {
    // 2026-01-15 12:00:00 UTC = 2026-01-15 13:00:00 +01 (standard)
    const instant = Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = 0,
        .seconds = 1768478400,
    };
    const dt = instant.to(.@"Africa/Casablanca");
    try testing.expectEqual(@as(u8, 13), dt.hour);
}

test "UTC to Casablanca during Ramadan 2030" {
    // Ramadan period 2030: Dec 22 2030 - Jan 26 2031
    // 2031-01-15 12:00:00 UTC = 2031-01-15 12:00:00 +00 (Ramadan, DST -1)
    const instant = Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = 0,
        .seconds = 1926244800,
    };
    const dt = instant.to(.@"Africa/Casablanca");
    try testing.expectEqual(@as(u8, 12), dt.hour);
}

test "round-trip UTC through Casablanca" {
    const original = Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = 0,
        .seconds = 1768478400,
    };
    const dt = original.to(.@"Africa/Casablanca");
    const back = dt.utc();
    try testing.expectEqual(original.seconds, back.seconds);
    try testing.expectEqual(Adjustment.none, back.adjustment);
}

test "round-trip UTC through Gaza" {
    const original = Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = 0,
        .seconds = 1752580800,
    };
    const dt = original.to(.@"Asia/Gaza");
    const back = dt.utc();
    try testing.expectEqual(original.seconds, back.seconds);
    try testing.expectEqual(Adjustment.none, back.adjustment);
}

test "fixed offset timezone no DST" {
    // 2025-07-15 12:00:00 UTC = 2025-07-15 21:00:00 JST (UTC+9, no DST)
    const instant = Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = 0,
        .seconds = 1752580800,
    };
    const dt = instant.to(.@"Asia/Tokyo");
    try testing.expectEqual(@as(u8, 21), dt.hour);
}

test "round-trip UTC through Tokyo" {
    const original = Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = 0,
        .seconds = 1752580800,
    };
    const dt = original.to(.@"Asia/Tokyo");
    const back = dt.utc();
    try testing.expectEqual(original.seconds, back.seconds);
    try testing.expectEqual(Adjustment.none, back.adjustment);
}

test "India half-hour offset" {
    // 2025-07-15 12:00:00 UTC = 2025-07-15 17:30:00 IST (UTC+5:30)
    const instant = Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = 0,
        .seconds = 1752580800,
    };
    const dt = instant.to(.@"Asia/Kolkata");
    try testing.expectEqual(@as(u8, 17), dt.hour);
    try testing.expectEqual(@as(u8, 30), dt.minute);
}

test "Nepal quarter-hour offset" {
    // 2025-07-15 12:00:00 UTC = 2025-07-15 17:45:00 NPT (UTC+5:45)
    const instant = Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = 0,
        .seconds = 1752580800,
    };
    const dt = instant.to(.@"Asia/Kathmandu");
    try testing.expectEqual(@as(u8, 17), dt.hour);
    try testing.expectEqual(@as(u8, 45), dt.minute);
}

test "add zero nanoseconds" {
    const original = Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = 500,
        .seconds = 1736942400,
    };
    const result = original.add(0);
    try testing.expectEqual(original.seconds, result.seconds);
    try testing.expectEqual(original.nanoseconds, result.nanoseconds);
}

test "add one second" {
    const original = Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = 0,
        .seconds = 1736942400,
    };
    const result = original.add(Second);
    try testing.expectEqual(@as(i64, 1736942401), result.seconds);
    try testing.expectEqual(@as(u32, 0), result.nanoseconds);
}

test "add nanoseconds with carry" {
    const original = Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = 999_999_000,
        .seconds = 1736942400,
    };
    const result = original.add(2_000);
    try testing.expectEqual(@as(i64, 1736942401), result.seconds);
    try testing.expectEqual(@as(u32, 1_000), result.nanoseconds);
}

test "add negative duration" {
    const original = Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = 0,
        .seconds = 1736942400,
    };
    const result = original.add(-30 * Minute);
    try testing.expectEqual(@as(i64, 1736940600), result.seconds);
}

test "subtract nanoseconds with borrow" {
    const original = Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = 500,
        .seconds = 1736942400,
    };
    const result = original.add(-1_000);
    try testing.expectEqual(@as(i64, 1736942399), result.seconds);
    try testing.expectEqual(@as(u32, 999_999_500), result.nanoseconds);
}

test "add preserves monotonic" {
    const original = Instant{
        .adjustment = .none,
        .monotonic = 5_000_000_000,
        .nanoseconds = 0,
        .seconds = 1736942400,
    };
    const result = original.add(2 * Second);
    try testing.expectEqual(@as(i64, 7_000_000_000), result.monotonic);
}

test "add without monotonic keeps zero" {
    const original = Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = 0,
        .seconds = 1736942400,
    };
    const result = original.add(2 * Second);
    try testing.expectEqual(@as(i64, 0), result.monotonic);
}

test "add clears adjustment" {
    const original = Instant{
        .adjustment = .shifted_forward,
        .monotonic = 0,
        .nanoseconds = 0,
        .seconds = 1736942400,
    };
    const result = original.add(Second);
    try testing.expectEqual(Adjustment.none, result.adjustment);
}

test "add one week" {
    const original = Instant{
        .adjustment = .none,
        .monotonic = 0,
        .nanoseconds = 0,
        .seconds = 1736942400,
    };
    const result = original.add(Week);
    try testing.expectEqual(@as(i64, 1736942400 + 604800), result.seconds);
}

test "rfc3339 UTC" {
    const dt = DateTime{
        .year = 2025,
        .month = .march,
        .day = 21,
        .hour = 14,
        .minute = 30,
        .second = 0,
        .nanosecond = 0,
        .timezone = .UTC,
    };
    var buf: [35]u8 = undefined;
    try testing.expectEqualStrings("2025-03-21T14:30:00Z", dt.rfc3339(&buf).?);
}

test "rfc3339 with nanoseconds" {
    const dt = DateTime{
        .year = 2025,
        .month = .january,
        .day = 1,
        .hour = 0,
        .minute = 0,
        .second = 0,
        .nanosecond = 123_456_789,
        .timezone = .UTC,
    };
    var buf: [35]u8 = undefined;
    try testing.expectEqualStrings("2025-01-01T00:00:00.123456789Z", dt.rfc3339(&buf).?);
}

test "rfc3339 trailing zeros trimmed" {
    const dt = DateTime{
        .year = 2025,
        .month = .june,
        .day = 15,
        .hour = 12,
        .minute = 0,
        .second = 0,
        .nanosecond = 100_000_000,
        .timezone = .UTC,
    };
    var buf: [35]u8 = undefined;
    try testing.expectEqualStrings("2025-06-15T12:00:00.1Z", dt.rfc3339(&buf).?);
}

test "rfc3339 positive offset" {
    const dt = DateTime{
        .year = 2025,
        .month = .july,
        .day = 15,
        .hour = 21,
        .minute = 0,
        .second = 0,
        .nanosecond = 0,
        .timezone = .@"Asia/Tokyo",
    };
    var buf: [35]u8 = undefined;
    try testing.expectEqualStrings("2025-07-15T21:00:00+09:00", dt.rfc3339(&buf).?);
}

test "rfc3339 negative offset" {
    const dt = DateTime{
        .year = 2025,
        .month = .january,
        .day = 15,
        .hour = 7,
        .minute = 0,
        .second = 0,
        .nanosecond = 0,
        .timezone = .@"America/New_York",
    };
    var buf: [35]u8 = undefined;
    try testing.expectEqualStrings("2025-01-15T07:00:00-05:00", dt.rfc3339(&buf).?);
}

test "rfc3339 half hour offset" {
    const dt = DateTime{
        .year = 2025,
        .month = .july,
        .day = 15,
        .hour = 17,
        .minute = 30,
        .second = 0,
        .nanosecond = 0,
        .timezone = .@"Asia/Kolkata",
    };
    var buf: [35]u8 = undefined;
    try testing.expectEqualStrings("2025-07-15T17:30:00+05:30", dt.rfc3339(&buf).?);
}

test "rfc3339 quarter hour offset" {
    const dt = DateTime{
        .year = 2025,
        .month = .july,
        .day = 15,
        .hour = 17,
        .minute = 45,
        .second = 0,
        .nanosecond = 0,
        .timezone = .@"Asia/Kathmandu",
    };
    var buf: [35]u8 = undefined;
    try testing.expectEqualStrings("2025-07-15T17:45:00+05:45", dt.rfc3339(&buf).?);
}

test "rfc3339 DST offset" {
    const dt = DateTime{
        .year = 2025,
        .month = .july,
        .day = 15,
        .hour = 8,
        .minute = 0,
        .second = 0,
        .nanosecond = 0,
        .timezone = .@"America/New_York",
    };
    var buf: [35]u8 = undefined;
    try testing.expectEqualStrings("2025-07-15T08:00:00-04:00", dt.rfc3339(&buf).?);
}

test "rfc3339 negative year returns null" {
    const dt = DateTime{
        .year = -1,
        .month = .january,
        .day = 1,
        .hour = 0,
        .minute = 0,
        .second = 0,
        .nanosecond = 0,
        .timezone = .UTC,
    };
    var buf: [35]u8 = undefined;
    try testing.expect(dt.rfc3339(&buf) == null);
}

test "rfc3339 year above 9999 returns null" {
    const dt = DateTime{
        .year = 10000,
        .month = .january,
        .day = 1,
        .hour = 0,
        .minute = 0,
        .second = 0,
        .nanosecond = 0,
        .timezone = .UTC,
    };
    var buf: [35]u8 = undefined;
    try testing.expect(dt.rfc3339(&buf) == null);
}

test "parse rfc3339 UTC" {
    const instant = try parse_rfc3339("2025-03-21T14:30:00Z");
    const dt = instant.to(.UTC);
    try testing.expectEqual(@as(i32, 2025), dt.year);
    try testing.expectEqual(Month.march, dt.month);
    try testing.expectEqual(@as(u8, 21), dt.day);
    try testing.expectEqual(@as(u8, 14), dt.hour);
    try testing.expectEqual(@as(u8, 30), dt.minute);
    try testing.expectEqual(@as(u8, 0), dt.second);
}

test "parse rfc3339 with nanoseconds" {
    const instant = try parse_rfc3339("2025-01-01T00:00:00.123456789Z");
    try testing.expectEqual(@as(u32, 123_456_789), instant.nanoseconds);
}

test "parse rfc3339 fractional seconds padded" {
    const instant = try parse_rfc3339("2025-01-01T00:00:00.1Z");
    try testing.expectEqual(@as(u32, 100_000_000), instant.nanoseconds);
}

test "parse rfc3339 truncates excess fractional digits" {
    const instant = try parse_rfc3339("2025-01-01T00:00:00.1234567891234Z");
    try testing.expectEqual(@as(u32, 123_456_789), instant.nanoseconds);
}

test "parse rfc3339 positive offset" {
    // 2025-07-15T21:00:00+09:00 = 2025-07-15T12:00:00Z
    const instant = try parse_rfc3339("2025-07-15T21:00:00+09:00");
    const dt = instant.to(.UTC);
    try testing.expectEqual(@as(u8, 12), dt.hour);
}

test "parse rfc3339 negative offset" {
    // 2025-01-15T07:00:00-05:00 = 2025-01-15T12:00:00Z
    const instant = try parse_rfc3339("2025-01-15T07:00:00-05:00");
    const dt = instant.to(.UTC);
    try testing.expectEqual(@as(u8, 12), dt.hour);
}

test "parse rfc3339 half hour offset" {
    // 2025-07-15T17:30:00+05:30 = 2025-07-15T12:00:00Z
    const instant = try parse_rfc3339("2025-07-15T17:30:00+05:30");
    const dt = instant.to(.UTC);
    try testing.expectEqual(@as(u8, 12), dt.hour);
    try testing.expectEqual(@as(u8, 0), dt.minute);
}

test "parse rfc3339 lowercase t and z" {
    const instant = try parse_rfc3339("2025-03-21t14:30:00z");
    const dt = instant.to(.UTC);
    try testing.expectEqual(@as(u8, 14), dt.hour);
}

test "parse rfc3339 no offset treated as UTC" {
    const instant = try parse_rfc3339("2025-03-21T14:30:00");
    const dt = instant.to(.UTC);
    try testing.expectEqual(@as(u8, 14), dt.hour);
    try testing.expectEqual(@as(u8, 30), dt.minute);
}

test "parse rfc3339 no offset with fractional seconds" {
    const instant = try parse_rfc3339("2025-03-21T14:30:00.5");
    try testing.expectEqual(@as(u32, 500_000_000), instant.nanoseconds);
    const dt = instant.to(.UTC);
    try testing.expectEqual(@as(u8, 14), dt.hour);
}

test "parse rfc3339 round-trip" {
    const original = "2025-07-15T08:00:00-04:00";
    const instant = try parse_rfc3339(original);
    const dt = instant.to(.@"America/New_York");
    var buf: [35]u8 = undefined;
    try testing.expectEqualStrings(original, dt.rfc3339(&buf).?);
}

test "parse rfc3339 round-trip UTC" {
    const original = "2025-03-21T14:30:00Z";
    const instant = try parse_rfc3339(original);
    const dt = instant.to(.UTC);
    var buf: [35]u8 = undefined;
    try testing.expectEqualStrings(original, dt.rfc3339(&buf).?);
}

test "parse rfc3339 round-trip with nanoseconds" {
    const original = "2025-01-01T00:00:00.123456789Z";
    const instant = try parse_rfc3339(original);
    const dt = instant.to(.UTC);
    var buf: [35]u8 = undefined;
    try testing.expectEqualStrings(original, dt.rfc3339(&buf).?);
}

test "parse rfc3339 invalid too short" {
    try testing.expectError(error.InvalidRFC3339, parse_rfc3339("2025"));
}

test "parse rfc3339 invalid month" {
    try testing.expectError(error.InvalidRFC3339, parse_rfc3339("2025-13-01T00:00:00Z"));
}

test "parse rfc3339 invalid hour" {
    try testing.expectError(error.InvalidRFC3339, parse_rfc3339("2025-01-01T25:00:00Z"));
}

test "parse rfc3339 invalid trailing content" {
    try testing.expectError(error.InvalidRFC3339, parse_rfc3339("2025-01-01T00:00:00Zextra"));
}

test "parse rfc3339 invalid separator" {
    try testing.expectError(error.InvalidRFC3339, parse_rfc3339("2025/01/01T00:00:00Z"));
}

test "parse rfc3339 invalid non-numeric" {
    try testing.expectError(error.InvalidRFC3339, parse_rfc3339("abcd-01-01T00:00:00Z"));
}

test "parse duration seconds" {
    try testing.expectEqual(@as(i64, 10 * Second), try parse_duration("10s"));
}

test "parse duration minutes" {
    try testing.expectEqual(@as(i64, 5 * Minute), try parse_duration("5m"));
}

test "parse duration hours" {
    try testing.expectEqual(@as(i64, 2 * Hour), try parse_duration("2h"));
}

test "parse duration combined" {
    try testing.expectEqual(@as(i64, 1 * Hour + 30 * Minute + 10 * Second), try parse_duration("1h30m10s"));
}

test "parse duration milliseconds" {
    try testing.expectEqual(@as(i64, 500 * Millisecond), try parse_duration("500ms"));
}

test "parse duration microseconds" {
    try testing.expectEqual(@as(i64, 100 * Microsecond), try parse_duration("100us"));
}

test "parse duration nanoseconds" {
    try testing.expectEqual(@as(i64, 42 * Nanosecond), try parse_duration("42ns"));
}

test "parse duration negative" {
    try testing.expectEqual(@as(i64, -30 * Second), try parse_duration("-30s"));
}

test "parse duration empty" {
    try testing.expectError(error.InvalidDuration, parse_duration(""));
}

test "parse duration no unit" {
    try testing.expectError(error.InvalidDuration, parse_duration("42"));
}

test "parse duration invalid unit" {
    try testing.expectError(error.InvalidDuration, parse_duration("10x"));
}

test "parse duration just sign" {
    try testing.expectError(error.InvalidDuration, parse_duration("-"));
}

test "from_unix" {
    const instant = from_unix(1736942400, 500);
    try testing.expectEqual(@as(i64, 1736942400), instant.seconds);
    try testing.expectEqual(@as(u32, 500), instant.nanoseconds);
}

test "from_unix_millis" {
    const instant = from_unix_milliseconds(1736942400_500);
    try testing.expectEqual(@as(i64, 1736942400), instant.seconds);
    try testing.expectEqual(@as(u32, 500_000_000), instant.nanoseconds);
}

test "from_unix_nanos" {
    const instant = from_unix_nanoseconds(1736942400_123_456_789);
    try testing.expectEqual(@as(i64, 1736942400), instant.seconds);
    try testing.expectEqual(@as(u32, 123_456_789), instant.nanoseconds);
}

test "unix_millis" {
    const instant = from_unix(1736942400, 500_000_000);
    try testing.expectEqual(@as(i64, 1736942400_500), instant.unix_milliseconds());
}

test "unix_nanos" {
    const instant = from_unix(1736942400, 123_456_789);
    try testing.expectEqual(@as(i128, 1736942400_123_456_789), instant.unix_nanoseconds());
}

test "before" {
    const a = from_unix(100, 0);
    const b = from_unix(200, 0);
    try testing.expect(a.before(b));
    try testing.expect(!b.before(a));
}

test "before nanosecond precision" {
    const a = from_unix(100, 500);
    const b = from_unix(100, 600);
    try testing.expect(a.before(b));
    try testing.expect(!b.before(a));
}

test "after" {
    const a = from_unix(200, 0);
    const b = from_unix(100, 0);
    try testing.expect(a.after(b));
    try testing.expect(!b.after(a));
}

test "equal" {
    const a = from_unix(100, 500);
    const b = from_unix(100, 500);
    try testing.expect(a.equal(b));
}

test "not equal" {
    const a = from_unix(100, 500);
    const b = from_unix(100, 501);
    try testing.expect(!a.equal(b));
}

test "from_unix_millis negative" {
    const instant = from_unix_milliseconds(-500);
    try testing.expectEqual(@as(i64, -1), instant.seconds);
    try testing.expectEqual(@as(u32, 500_000_000), instant.nanoseconds);
}

test "from_unix round-trip through unix_nanos" {
    const original = from_unix(1752580800, 999_999_999);
    const back = from_unix_nanoseconds(original.unix_nanoseconds());
    try testing.expect(original.equal(back));
}

test "rule_hash UTC" {
    const h = rule_hash(.UTC, 2026);
    try testing.expect(h != 0);
}

test "rule_hash deterministic" {
    const a = rule_hash(.@"America/New_York", 2026);
    const b = rule_hash(.@"America/New_York", 2026);
    try testing.expectEqual(a, b);
}

test "rule_hash differs across timezones" {
    const ny = rule_hash(.@"America/New_York", 2026);
    const tokyo = rule_hash(.@"Asia/Tokyo", 2026);
    try testing.expect(ny != tokyo);
}

test "rule_hash same rules same hash" {
    // Europe/Berlin and Europe/Paris currently follow the same rules.
    const a = rule_hash(.@"Europe/Berlin", 2026);
    const b = rule_hash(.@"Europe/Paris", 2026);
    try testing.expectEqual(a, b);
}

test "rule_hash DST vs no DST differ" {
    const ny = rule_hash(.@"America/New_York", 2026);
    const utc = rule_hash(.UTC, 2026);
    try testing.expect(ny != utc);
}

test "rule_hash continuous DST" {
    const h = rule_hash(.@"Africa/Casablanca", 2026);
    try testing.expect(h != 0);
}

test "rule_hash continuous DST deterministic" {
    const a = rule_hash(.@"Africa/Casablanca", 2026);
    const b = rule_hash(.@"Africa/Casablanca", 2026);
    try testing.expectEqual(a, b);
}

test "utc_offset UTC is zero" {
    const instant = from_unix(1752580800, 0);
    try testing.expectEqual(@as(i32, 0), instant.utc_offset(.UTC));
}

test "utc_offset New York EST" {
    // 2025-01-15 12:00:00 UTC -> EST is -5h = -18000s
    const instant = from_unix(1736942400, 0);
    try testing.expectEqual(@as(i32, -18000), instant.utc_offset(.@"America/New_York"));
}

test "utc_offset New York EDT" {
    // 2025-07-15 12:00:00 UTC -> EDT is -4h = -14400s
    const instant = from_unix(1752580800, 0);
    try testing.expectEqual(@as(i32, -14400), instant.utc_offset(.@"America/New_York"));
}

test "utc_offset Tokyo no DST" {
    const instant = from_unix(1752580800, 0);
    try testing.expectEqual(@as(i32, 32400), instant.utc_offset(.@"Asia/Tokyo"));
}

test "utc_offset India half-hour" {
    const instant = from_unix(1752580800, 0);
    try testing.expectEqual(@as(i32, 19800), instant.utc_offset(.@"Asia/Kolkata"));
}

test "utc_offset consistent with to" {
    const instant = from_unix(1752580800, 0);
    const dt = instant.to(.@"America/New_York");
    const offset = instant.utc_offset(.@"America/New_York");
    const back = datetime_from(instant.seconds + offset, instant.nanoseconds, .@"America/New_York");
    try testing.expectEqual(dt.hour, back.hour);
    try testing.expectEqual(dt.minute, back.minute);
}
