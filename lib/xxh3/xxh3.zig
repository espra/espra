// Public Domain (-) 2026-present, The Espra Core Authors.
// See the Espra Core UNLICENSE file for details.

const xxhash = struct {
    const XXH128_hash_t = extern struct {
        low64: u64,
        high64: u64,
    };

    extern fn XXH3_64bits(input: ?[*]const u8, length: usize) u64;
    extern fn XXH3_64bits_withSeed(input: ?[*]const u8, length: usize, seed: u64) u64;
    extern fn XXH3_128bits(input: ?[*]const u8, length: usize) XXH128_hash_t;
    extern fn XXH3_128bits_withSeed(input: ?[*]const u8, length: usize, seed: u64) XXH128_hash_t;
};

pub const Hash128 = struct {
    low: u64,
    high: u64,
};

pub fn hash64(data: []const u8) u64 {
    return xxhash.XXH3_64bits(data.ptr, data.len);
}

pub fn hash64_with_seed(data: []const u8, seed: u64) u64 {
    return xxhash.XXH3_64bits_withSeed(data.ptr, data.len, seed);
}

pub fn hash128(data: []const u8) Hash128 {
    const d = xxhash.XXH3_128bits(data.ptr, data.len);
    return Hash128{
        .low = d.low64,
        .high = d.high64,
    };
}

pub fn hash128_with_seed(data: []const u8, seed: u64) Hash128 {
    const d = xxhash.XXH3_128bits_withSeed(data.ptr, data.len, seed);
    return Hash128{
        .low = d.low64,
        .high = d.high64,
    };
}

const std = @import("std");
const testing = std.testing;

test "hash64 empty" {
    try testing.expectEqual(@as(u64, 0x2D06800538D394C2), hash64(""));
}

test "hash64 single byte" {
    try testing.expectEqual(@as(u64, 0xE6C632B61E964E1F), hash64("a"));
}

test "hash64 short string" {
    try testing.expectEqual(@as(u64, 0x78AF5F94892F3950), hash64("abc"));
}

test "hash64 13 bytes" {
    try testing.expectEqual(@as(u64, 0x60415D5F616602AA), hash64("Hello, World!"));
}

test "hash64 16 bytes" {
    try testing.expectEqual(@as(u64, 0x64439946D8FA212D), hash64("0123456789abcdef"));
}

test "hash64 17 bytes" {
    try testing.expectEqual(@as(u64, 0xD2E63ED5466F5C32), hash64("0123456789abcdefg"));
}

test "hash64 deterministic" {
    const a = hash64("deterministic");
    const b = hash64("deterministic");
    try testing.expectEqual(a, b);
}

test "hash64 different inputs differ" {
    try testing.expect(hash64("hello") != hash64("world"));
}

test "hash64_with_seed differs from unseeded" {
    const a = hash64("test");
    const b = hash64_with_seed("test", 42);
    try testing.expect(a != b);
}

test "hash64_with_seed value" {
    try testing.expectEqual(@as(u64, 0xCF50C49225E87934), hash64_with_seed("test", 42));
}

test "hash128 empty" {
    const h = hash128("");
    try testing.expectEqual(@as(u64, 0x6001C324468D497F), h.low);
    try testing.expectEqual(@as(u64, 0x99AA06D3014798D8), h.high);
}

test "hash128 short string" {
    const h = hash128("abc");
    try testing.expectEqual(@as(u64, 0x78AF5F94892F3950), h.low);
    try testing.expectEqual(@as(u64, 0x06B05AB6733A6185), h.high);
}

test "hash128 13 bytes" {
    const h = hash128("Hello, World!");
    try testing.expectEqual(@as(u64, 0x77DB03842CD75395), h.low);
    try testing.expectEqual(@as(u64, 0x531DF2844447DD50), h.high);
}

test "hash128 16 bytes" {
    const h = hash128("0123456789abcdef");
    try testing.expectEqual(@as(u64, 0x0BEFB4873DBE58F8), h.low);
    try testing.expectEqual(@as(u64, 0xCCBA8085A0434E9E), h.high);
}

test "hash128 17 bytes" {
    const h = hash128("0123456789abcdefg");
    try testing.expectEqual(@as(u64, 0xC7401FB9F6FBF86B), h.low);
    try testing.expectEqual(@as(u64, 0xD54994A55733DB61), h.high);
}

test "hash128 deterministic" {
    const a = hash128("deterministic");
    const b = hash128("deterministic");
    try testing.expectEqual(a.low, b.low);
    try testing.expectEqual(a.high, b.high);
}

test "hash128 different inputs differ" {
    const a = hash128("hello");
    const b = hash128("world");
    try testing.expect(a.low != b.low or a.high != b.high);
}

test "hash128_with_seed differs from unseeded" {
    const a = hash128("test");
    const b = hash128_with_seed("test", 42);
    try testing.expect(a.low != b.low or a.high != b.high);
}
