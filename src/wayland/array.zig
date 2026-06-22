//! wl_array equivalent: a growable, raw byte buffer.
//!
//! Mirrors libwayland's `struct wl_array` (wayland-util.h/.c), the container the
//! protocol uses for variable-length data (keymaps, the registry's global list,
//! etc.). It is a flat region of bytes with a logical `size`, a backing
//! capacity `alloc`, and a `data` pointer. Growth doubles capacity, starting at
//! 16 bytes, like libwayland.
//!
//! Unlike libwayland (which uses malloc/realloc/free), this takes an explicit
//! allocator, matching this library's Zig style.

const std = @import("std");

pub const Array = struct {
    /// Logical size in bytes currently in use.
    size: usize = 0,
    /// Allocated capacity in bytes.
    alloc: usize = 0,
    /// Backing storage, or null when no capacity is allocated yet.
    data: ?[*]u8 = null,

    /// An empty array (no allocation). Mirrors wl_array_init.
    pub fn init() Array {
        return .{};
    }

    /// Free the backing storage and reset to empty. Mirrors wl_array_release.
    pub fn release(self: *Array, allocator: std.mem.Allocator) void {
        if (self.data) |d| allocator.free(d[0..self.alloc]);
        self.* = .{};
    }

    /// Grow the logical size by `size` bytes and return a slice over the newly
    /// added region. Reallocates (doubling capacity from a base of 16) when the
    /// current capacity is too small. Mirrors wl_array_add.
    pub fn add(self: *Array, allocator: std.mem.Allocator, size: usize) ![]u8 {
        if (self.size + size > self.alloc) {
            var new_alloc: usize = if (self.alloc > 0) self.alloc else 16;
            while (new_alloc < self.size + size) new_alloc *= 2;

            const new_data = if (self.data) |d|
                try allocator.realloc(d[0..self.alloc], new_alloc)
            else
                try allocator.alloc(u8, new_alloc);
            self.data = new_data.ptr;
            self.alloc = new_alloc;
        }

        const start = self.size;
        self.size += size;
        return self.data.?[start..self.size];
    }

    /// Replace this array's contents with a copy of `source`'s bytes.
    /// Mirrors wl_array_copy.
    pub fn copy(self: *Array, allocator: std.mem.Allocator, source: *const Array) !void {
        self.size = 0;
        const dst = try self.add(allocator, source.size);
        if (source.data) |src| @memcpy(dst, src[0..source.size]);
    }

    /// The bytes currently in use as a slice.
    pub fn slice(self: *const Array) []u8 {
        if (self.data) |d| return d[0..self.size];
        return &.{};
    }
};

test "Array add and read back" {
    const a = std.testing.allocator;
    var arr = Array.init();
    defer arr.release(a);

    const region = try arr.add(a, 4);
    region[0] = 1;
    region[1] = 2;
    region[2] = 3;
    region[3] = 4;
    try std.testing.expectEqual(@as(usize, 4), arr.size);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, arr.slice());
}

test "Array grows across a realloc boundary" {
    const a = std.testing.allocator;
    var arr = Array.init();
    defer arr.release(a);

    // First add of 16 fills the initial capacity exactly.
    const first = try arr.add(a, 16);
    for (first, 0..) |*b, i| b.* = @intCast(i);
    try std.testing.expectEqual(@as(usize, 16), arr.alloc);

    // Next add forces a doubling realloc to 32.
    const second = try arr.add(a, 8);
    for (second, 0..) |*b, i| b.* = @intCast(100 + i);
    try std.testing.expectEqual(@as(usize, 24), arr.size);
    try std.testing.expectEqual(@as(usize, 32), arr.alloc);

    // Pre-realloc bytes survived the move.
    const s = arr.slice();
    for (0..16) |i| try std.testing.expectEqual(@as(u8, @intCast(i)), s[i]);
    for (0..8) |i| try std.testing.expectEqual(@as(u8, @intCast(100 + i)), s[16 + i]);
}

test "Array copy duplicates source contents" {
    const a = std.testing.allocator;
    var src = Array.init();
    defer src.release(a);
    const region = try src.add(a, 5);
    @memcpy(region, "hello");

    var dst = Array.init();
    defer dst.release(a);
    try dst.copy(a, &src);

    try std.testing.expectEqualSlices(u8, "hello", dst.slice());
    // Independent storage.
    try std.testing.expect(dst.data.? != src.data.?);
}
