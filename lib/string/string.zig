// Public Domain (-) 2026-present, The Espra Core Authors.
// See the Espra Core UNLICENSE file for details.

const std = @import("std");

/// Provides the restricted edit distance between two ASCII strings.
///
/// You may also see this referred to as the optimal string alignment distance
/// or the restricted Damerau-Levenshtein distance.
pub fn ascii_distance(allocator: std.mem.Allocator, a: []const u8, b: []const u8) !usize {
    const m = a.len;
    const n = b.len;

    if (m == 0) {
        return n;
    }
    if (n == 0) {
        return m;
    }

    const cols = n + 1;
    const matrix = try allocator.alloc(usize, (m + 1) * cols);
    defer allocator.free(matrix);

    for (0..m + 1) |i| {
        matrix[i * cols] = i;
    }
    for (0..n + 1) |j| {
        matrix[j] = j;
    }

    var i: usize = 1;
    while (i <= m) : (i += 1) {
        var j: usize = 1;
        while (j <= n) : (j += 1) {
            const cost: usize = if (a[i - 1] == b[j - 1]) 0 else 1;
            const deletion = matrix[(i - 1) * cols + j] + 1;
            const insertion = matrix[i * cols + (j - 1)] + 1;
            const substitution = matrix[(i - 1) * cols + (j - 1)] + cost;
            var lowest = @min(deletion, insertion, substitution);
            if (i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]) {
                const transposition = matrix[(i - 2) * cols + (j - 2)] + cost;
                lowest = @min(lowest, transposition);
            }
            matrix[i * cols + j] = lowest;
        }
    }
    return matrix[m * cols + n];
}

/// Matches candidates within the given restricted edit distance.
///
/// Also does exact and fuzzy matching of prefixes. Caller is responsible for
/// freeing the returned slice.
pub fn match_within_ascii_distance(allocator: std.mem.Allocator, input: []const u8, candidates: []const []const u8, max_distance: usize) ![]const []const u8 {
    var matches: std.ArrayList([]const u8) = .empty;
    errdefer matches.deinit(allocator);
    // NOTE(tav): We scale down the limit to reduce invalid matches.
    const limit = @min(max_distance, input.len / 3);
    for (candidates) |candidate| {
        if (std.ascii.startsWithIgnoreCase(candidate, input)) {
            try matches.append(allocator, candidate);
            continue;
        }
        if (candidate.len >= input.len) {
            const distance = try ascii_distance(allocator, input, candidate[0..input.len]);
            if (distance <= limit) {
                try matches.append(allocator, candidate);
                continue;
            }
        }
        const distance = try ascii_distance(allocator, input, candidate);
        if (distance <= limit) {
            try matches.append(allocator, candidate);
        }
    }
    return matches.toOwnedSlice(allocator);
}

const testing = std.testing;

test "ascii_distance" {
    const cases = [_]struct {
        name: []const u8,
        a: []const u8,
        b: []const u8,
        expected: usize,
    }{
        // base cases
        .{ .name = "both empty", .a = "", .b = "", .expected = 0 },
        .{ .name = "a empty", .a = "", .b = "abcd", .expected = 4 },
        .{ .name = "b empty", .a = "abcd", .b = "", .expected = 4 },
        .{ .name = "identical short", .a = "a", .b = "a", .expected = 0 },
        .{ .name = "identical long", .a = "hello", .b = "hello", .expected = 0 },
        // single-character edits
        .{ .name = "insertion suffix", .a = "cat", .b = "cats", .expected = 1 },
        .{ .name = "insertion middle", .a = "cat", .b = "coat", .expected = 1 },
        .{ .name = "deletion suffix", .a = "cats", .b = "cat", .expected = 1 },
        .{ .name = "deletion middle", .a = "coat", .b = "cat", .expected = 1 },
        .{ .name = "substitution first", .a = "cat", .b = "bat", .expected = 1 },
        .{ .name = "substitution last", .a = "cat", .b = "car", .expected = 1 },
        // transpositions
        .{ .name = "transposition minimal", .a = "ab", .b = "ba", .expected = 1 },
        .{ .name = "transposition in word", .a = "form", .b = "from", .expected = 1 },
        .{ .name = "transposition typo", .a = "smtih", .b = "smith", .expected = 1 },
        .{ .name = "transposition middle", .a = "chekcout", .b = "checkout", .expected = 1 },
        // OSA vs true Damerau-Levenshtein: true DL would give 2 here
        .{ .name = "OSA vs DL divergence", .a = "ca", .b = "abc", .expected = 3 },
        // textbook examples
        .{ .name = "kitten to sitting", .a = "kitten", .b = "sitting", .expected = 3 },
        .{ .name = "saturday to sunday", .a = "saturday", .b = "sunday", .expected = 3 },
        // byte-level, so case differences count
        .{ .name = "case sensitive one", .a = "Cat", .b = "cat", .expected = 1 },
        .{ .name = "case sensitive all", .a = "ABC", .b = "abc", .expected = 3 },
    };

    for (cases) |c| {
        const forward = try ascii_distance(testing.allocator, c.a, c.b);
        testing.expectEqual(c.expected, forward) catch |err| {
            std.debug.print("case '{s}': expected {d}, got {d}\n", .{ c.name, c.expected, forward });
            return err;
        };
        // OSA distance is symmetric; free verification for every case.
        const reverse = try ascii_distance(testing.allocator, c.b, c.a);
        testing.expectEqual(forward, reverse) catch |err| {
            std.debug.print("case '{s}' reversed: expected {d}, got {d}\n", .{ c.name, forward, reverse });
            return err;
        };
    }
}

test "match_within_ascii_distance" {
    const cases = [_]struct {
        name: []const u8,
        input: []const u8,
        candidates: []const []const u8,
        max_distance: usize,
        expected: []const []const u8,
    }{
        .{
            .name = "empty candidates",
            .input = "hello",
            .candidates = &.{},
            .max_distance = 2,
            .expected = &.{},
        },
        .{
            .name = "exact prefix",
            .input = "che",
            .candidates = &.{ "checkout", "commit", "push", "pull" },
            .max_distance = 2,
            .expected = &.{"checkout"},
        },
        .{
            .name = "case-insensitive prefix",
            .input = "com",
            .candidates = &.{ "Checkout", "COMMIT", "push" },
            .max_distance = 2,
            .expected = &.{"COMMIT"},
        },
        .{
            .name = "multiple prefix hits preserve order",
            .input = "pu",
            .candidates = &.{ "push", "pull", "pop" },
            .max_distance = 2,
            .expected = &.{ "push", "pull" },
        },
        .{
            .name = "fuzzy prefix on partial-input typo",
            .input = "chek",
            .candidates = &.{ "checkout", "commit", "push", "pull" },
            .max_distance = 2,
            .expected = &.{"checkout"},
        },
        .{
            .name = "full fuzzy on complete-word typo",
            .input = "comit",
            .candidates = &.{ "checkout", "commit", "push", "pull" },
            .max_distance = 2,
            .expected = &.{"commit"},
        },
        .{
            .name = "transposition typo in full word",
            .input = "chekcout",
            .candidates = &.{ "checkout", "commit", "status" },
            .max_distance = 2,
            .expected = &.{"checkout"},
        },
        .{
            // input.len=2 -> limit=0, fuzzy disabled; only exact prefixes match.
            .name = "short input disables fuzzy",
            .input = "pu",
            .candidates = &.{ "push", "pull", "pop", "add" },
            .max_distance = 2,
            .expected = &.{ "push", "pull" },
        },
        .{
            .name = "no matches",
            .input = "xyzzy",
            .candidates = &.{ "checkout", "commit", "push", "pull" },
            .max_distance = 2,
            .expected = &.{},
        },
        .{
            .name = "max_distance 0 blocks fuzzy",
            .input = "chekcout",
            .candidates = &.{ "checkout", "commit" },
            .max_distance = 0,
            .expected = &.{},
        },
        .{
            .name = "max_distance 0 allows exact prefix",
            .input = "che",
            .candidates = &.{ "checkout", "commit" },
            .max_distance = 0,
            .expected = &.{"checkout"},
        },
        .{
            .name = "overlong input with short candidates",
            .input = "checkout",
            .candidates = &.{ "pop", "add" },
            .max_distance = 2,
            .expected = &.{},
        },
    };

    for (cases) |c| {
        const actual = try match_within_ascii_distance(testing.allocator, c.input, c.candidates, c.max_distance);
        defer testing.allocator.free(actual);

        testing.expectEqual(c.expected.len, actual.len) catch |err| {
            std.debug.print("case '{s}': expected {d} matches, got {d}\n", .{ c.name, c.expected.len, actual.len });
            return err;
        };
        for (c.expected, actual) |want, got| {
            testing.expectEqualStrings(want, got) catch |err| {
                std.debug.print("case '{s}': match mismatch (want '{s}', got '{s}')\n", .{ c.name, want, got });
                return err;
            };
        }
    }
}
