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
