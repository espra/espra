// Public Domain (-) 2026-present, The Espra Core Authors.
// See the Espra Core UNLICENSE file for details.

const std = @import("std");

/// The requested effort level for a model operation.
///
/// If the model doesn't support the requested level, `prefer` determines
/// whether to select a lower or higher supported level. If no level exists
/// in the preferred direction, then the other direction is used.
pub const Effort = struct {
    level: EffortLevel,
    prefer: PreferredDirection = .lower,

    pub fn resolve(self: Effort, supported: []const EffortLevel) EffortLevel {
        std.debug.assert(supported.len > 0);
        const target = @intFromEnum(self.level);
        switch (self.prefer) {
            .lower => {
                var best: ?EffortLevel = null;
                var lowest = supported[0];
                for (supported) |level| {
                    const v = @intFromEnum(level);
                    if (v <= target) {
                        if (best == null or v > @intFromEnum(best.?)) {
                            best = level;
                        }
                    }
                    if (v < @intFromEnum(lowest)) {
                        lowest = level;
                    }
                }
                return best orelse lowest;
            },
            .higher => {
                var best: ?EffortLevel = null;
                var highest = supported[0];
                for (supported) |level| {
                    const v = @intFromEnum(level);
                    if (v >= target) {
                        if (best == null or v < @intFromEnum(best.?)) {
                            best = level;
                        }
                    }
                    if (v > @intFromEnum(highest)) {
                        highest = level;
                    }
                }
                return best orelse highest;
            },
        }
    }
};

pub const EffortLevel = enum(u8) {
    min,
    xxlow,
    xlow,
    low,
    mlow,
    medium,
    mhigh,
    high,
    xhigh,
    xxhigh,
    max,
};

pub const PreferredDirection = enum {
    lower,
    higher,
};

const testing = std.testing;

test "resolve effort level" {
    const cases = [_]struct {
        name: []const u8,
        supported: []const EffortLevel,
        effort: Effort,
        expected: EffortLevel,
    }{
        .{
            .name = "exact match with .lower",
            .supported = &.{ .low, .medium, .high },
            .effort = .{ .level = .medium, .prefer = .lower },
            .expected = .medium,
        },
        .{
            .name = "exact match with .higher",
            .supported = &.{ .low, .medium, .high },
            .effort = .{ .level = .medium, .prefer = .higher },
            .expected = .medium,
        },
        .{
            .name = "rounds down with .lower",
            .supported = &.{ .low, .medium, .high },
            .effort = .{ .level = .mhigh, .prefer = .lower },
            .expected = .medium,
        },
        .{
            .name = "rounds up with .higher",
            .supported = &.{ .low, .medium, .high },
            .effort = .{ .level = .mlow, .prefer = .higher },
            .expected = .medium,
        },
        .{
            .name = "clamps up when nothing is lower",
            .supported = &.{ .high, .max },
            .effort = .{ .level = .low, .prefer = .lower },
            .expected = .high,
        },
        .{
            .name = "clamps down when nothing is higher",
            .supported = &.{ .min, .low },
            .effort = .{ .level = .high, .prefer = .higher },
            .expected = .low,
        },
        .{
            .name = "unsorted supported slice",
            .supported = &.{ .high, .low, .medium },
            .effort = .{ .level = .mhigh, .prefer = .lower },
            .expected = .medium,
        },
        .{
            .name = "single element with .lower",
            .supported = &.{.medium},
            .effort = .{ .level = .high, .prefer = .lower },
            .expected = .medium,
        },
        .{
            .name = "single element with .higher",
            .supported = &.{.medium},
            .effort = .{ .level = .low, .prefer = .higher },
            .expected = .medium,
        },
        .{
            .name = "boundary exact match with .lower",
            .supported = &.{ .medium, .high },
            .effort = .{ .level = .medium, .prefer = .lower },
            .expected = .medium,
        },
        .{
            .name = "boundary exact match with .higher",
            .supported = &.{ .low, .medium },
            .effort = .{ .level = .medium, .prefer = .higher },
            .expected = .medium,
        },
    };

    for (cases) |c| {
        const actual = c.effort.resolve(c.supported);
        testing.expectEqual(c.expected, actual) catch |err| {
            std.debug.print("case failed: {s}\n", .{c.name});
            return err;
        };
    }
}
