// Public Domain (-) 2026-present, The Espra Core Authors.
// See the Espra Core UNLICENSE file for details.

const std = @import("std");
const time = @import("time");

const Allocator = std.mem.Allocator;

pub const Config = struct {
    allocator: ?Allocator,
};

pub const Context = struct {
    allocator: Allocator,
};

pub const Spec = struct {
    func: *const fn (context: Context) void,
    name: []const u8,
};

const Count = struct {
    alloc: u64 = 0,
    alloc_bytes: u64 = 0,
    free: u64 = 0,
    free_bytes: u64 = 0,

    fn live_bytes(self: *const Count) u64 {
        return self.alloc_bytes - self.free_bytes;
    }

    fn live_objects(self: *const Count) u64 {
        return self.alloc - self.free;
    }

    fn remap(self: *Count, start: usize, end: usize) void {
        if (end == 0) {
            self.free += 1;
            self.free_bytes += start;
        } else if (end > start) {
            self.alloc_bytes += end - start;
        } else {
            self.free_bytes += start - end;
        }
    }

    fn reset(self: *Count) void {
        self.* = .{};
    }
};

const CountingAllocator = struct {
    base_allocator: Allocator,
    count: Count = .{},

    fn allocator(self: *CountingAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .free = free,
                .remap = remap,
                .resize = resize,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.base_allocator.vtable.alloc(self.base_allocator.ptr, len, alignment, ret_addr);
        if (result != null) {
            self.count.alloc += 1;
            self.count.alloc_bytes += len;
        }
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.base_allocator.vtable.free(self.base_allocator.ptr, memory, alignment, ret_addr);
        self.count.free += 1;
        self.count.free_bytes += memory.len;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.base_allocator.vtable.remap(self.base_allocator.ptr, memory, alignment, new_len, ret_addr);
        if (result != null) {
            self.count.remap(memory.len, new_len);
        }
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.base_allocator.vtable.resize(self.base_allocator.ptr, memory, alignment, new_len, ret_addr);
        if (result) {
            self.count.remap(memory.len, new_len);
        }
        return result;
    }
};

const Options = struct {
    filter: ?[]const u8,
};

pub fn run(comptime tuples: anytype, config: Config) !void {
    comptime var specs: [tuples.len]Spec = undefined;
    inline for (tuples, 0..) |tuple, i| {
        specs[i] = .{
            .func = tuple[1],
            .name = tuple[0],
        };
    }
    const s = specs;
    try run_specs(&s, config);
}

pub fn run_specs(specs: []const Spec, config: Config) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const internal = gpa.allocator();

    const allocator = config.allocator orelse internal;
}
