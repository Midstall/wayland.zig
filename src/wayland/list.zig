//! wl_list equivalent: an intrusive doubly-linked list.
//!
//! Mirrors libwayland's `struct wl_list` (wayland-util.h/.c). A `Link` is
//! embedded inside a host struct; the list itself is just a sentinel `Link`
//! whose `next`/`prev` form a circular ring. The host struct is recovered from
//! a `Link` via `@fieldParentPtr` (the Zig idiom for libwayland's
//! `wl_container_of`/`container_of`).
//!
//! Usage:
//!   const Item = struct { value: u32, link: Link };
//!   var list: Link = undefined;
//!   list.init();
//!   var a = Item{ .value = 1, .link = undefined };
//!   list.insert(&a.link);                 // push at head
//!   var it = list.iterator(Item, "link"); // typed iteration over hosts
//!   while (it.next()) |item| { ... }

const std = @import("std");

/// One link node. Embed this in host structs and use it as the list sentinel.
/// A freshly initialized sentinel points at itself (empty list).
pub const Link = struct {
    prev: *Link,
    next: *Link,

    /// Initialize a link as an empty list head (points at itself).
    /// Mirrors wl_list_init.
    pub fn init(self: *Link) void {
        self.prev = self;
        self.next = self;
    }

    /// Insert `elm` immediately after `self`. To push at the head of a list,
    /// call `head.insert(elm)`. To append at the tail, call
    /// `head.prev.insert(elm)`. Mirrors wl_list_insert(self, elm).
    pub fn insert(self: *Link, elm: *Link) void {
        elm.prev = self;
        elm.next = self.next;
        self.next.prev = elm;
        self.next = elm;
    }

    /// Append `elm` at the tail of the list whose head is `self`.
    /// Convenience for `self.prev.insert(elm)`.
    pub fn append(self: *Link, elm: *Link) void {
        self.prev.insert(elm);
    }

    /// Remove this link from whatever list it is in. Mirrors wl_list_remove.
    /// After removal the link's pointers are poisoned to catch double-removes.
    pub fn remove(self: *Link) void {
        self.prev.next = self.next;
        self.next.prev = self.prev;
        self.next = undefined;
        self.prev = undefined;
    }

    /// True if the list whose head is `self` is empty. Mirrors wl_list_empty.
    pub fn empty(self: *const Link) bool {
        return self.next == self;
    }

    /// Number of elements in the list whose head is `self` (O(n)).
    /// Mirrors wl_list_length.
    pub fn length(self: *const Link) usize {
        var count: usize = 0;
        var e = self.next;
        while (e != self) : (e = e.next) count += 1;
        return count;
    }

    /// Splice the contents of list `other` into the list `self` (after the
    /// head), leaving `other` dangling. Mirrors wl_list_insert_list.
    pub fn insertList(self: *Link, other: *Link) void {
        if (other.empty()) return;
        other.next.prev = self;
        other.prev.next = self.next;
        self.next.prev = other.prev;
        self.next = other.next;
    }

    /// Recover the host struct that embeds this link at field `field`.
    /// The Zig idiom for libwayland's wl_container_of / container_of.
    pub fn container(self: *Link, comptime Host: type, comptime field: []const u8) *Host {
        return @fieldParentPtr(field, self);
    }

    /// A forward iterator that yields host structs (`*Host`) given the name of
    /// the embedded `Link` field. Safe against the CURRENT element removing
    /// itself during iteration (it caches `next` before yielding), matching
    /// libwayland's wl_list_for_each_safe usage pattern.
    pub fn iterator(self: *Link, comptime Host: type, comptime field: []const u8) Iterator(Host, field) {
        return .{ .head = self, .cur = self.next, .next_cached = self.next.next };
    }
};

/// Typed, removal-safe iterator over the host structs of a list.
pub fn Iterator(comptime Host: type, comptime field: []const u8) type {
    return struct {
        const Self = @This();
        head: *Link,
        cur: *Link,
        next_cached: *Link,

        /// Return the next host struct, or null at the end of the list.
        pub fn next(self: *Self) ?*Host {
            if (self.cur == self.head) return null;
            const link = self.cur;
            self.cur = self.next_cached;
            self.next_cached = self.next_cached.next;
            return @fieldParentPtr(field, link);
        }
    };
}

const Item = struct {
    value: u32,
    link: Link,
};

test "Link insert, iterate in order, length" {
    var head: Link = undefined;
    head.init();
    try std.testing.expect(head.empty());
    try std.testing.expectEqual(@as(usize, 0), head.length());

    var a = Item{ .value = 1, .link = undefined };
    var b = Item{ .value = 2, .link = undefined };
    var c = Item{ .value = 3, .link = undefined };

    // Append at tail so iteration order is 1, 2, 3.
    head.append(&a.link);
    head.append(&b.link);
    head.append(&c.link);

    try std.testing.expect(!head.empty());
    try std.testing.expectEqual(@as(usize, 3), head.length());

    var it = head.iterator(Item, "link");
    try std.testing.expectEqual(@as(u32, 1), it.next().?.value);
    try std.testing.expectEqual(@as(u32, 2), it.next().?.value);
    try std.testing.expectEqual(@as(u32, 3), it.next().?.value);
    try std.testing.expect(it.next() == null);
}

test "Link insert at head pushes to front" {
    var head: Link = undefined;
    head.init();
    var a = Item{ .value = 1, .link = undefined };
    var b = Item{ .value = 2, .link = undefined };
    head.insert(&a.link);
    head.insert(&b.link); // b is now first

    var it = head.iterator(Item, "link");
    try std.testing.expectEqual(@as(u32, 2), it.next().?.value);
    try std.testing.expectEqual(@as(u32, 1), it.next().?.value);
}

test "Link remove middle" {
    var head: Link = undefined;
    head.init();
    var a = Item{ .value = 1, .link = undefined };
    var b = Item{ .value = 2, .link = undefined };
    var c = Item{ .value = 3, .link = undefined };
    head.append(&a.link);
    head.append(&b.link);
    head.append(&c.link);

    b.link.remove();
    try std.testing.expectEqual(@as(usize, 2), head.length());

    var it = head.iterator(Item, "link");
    try std.testing.expectEqual(@as(u32, 1), it.next().?.value);
    try std.testing.expectEqual(@as(u32, 3), it.next().?.value);
    try std.testing.expect(it.next() == null);
}

test "Link container recovers host via @fieldParentPtr" {
    var a = Item{ .value = 42, .link = undefined };
    const host = a.link.container(Item, "link");
    try std.testing.expectEqual(@as(u32, 42), host.value);
    try std.testing.expectEqual(&a, host);
}

test "Link insertList splices another list" {
    var head: Link = undefined;
    head.init();
    var other: Link = undefined;
    other.init();

    var a = Item{ .value = 1, .link = undefined };
    var b = Item{ .value = 2, .link = undefined };
    other.append(&a.link);
    other.append(&b.link);

    head.insertList(&other);
    try std.testing.expectEqual(@as(usize, 2), head.length());
    var it = head.iterator(Item, "link");
    try std.testing.expectEqual(@as(u32, 1), it.next().?.value);
    try std.testing.expectEqual(@as(u32, 2), it.next().?.value);
}

test "Link iterator tolerates current element removing itself" {
    var head: Link = undefined;
    head.init();
    var items: [4]Item = undefined;
    for (&items, 0..) |*item, i| {
        item.value = @intCast(i);
        head.append(&item.link);
    }
    // Remove every element as we visit it; all should still be visited.
    var seen: [4]bool = .{ false, false, false, false };
    var it = head.iterator(Item, "link");
    while (it.next()) |item| {
        seen[item.value] = true;
        item.link.remove();
    }
    for (seen) |s| try std.testing.expect(s);
    try std.testing.expect(head.empty());
}
