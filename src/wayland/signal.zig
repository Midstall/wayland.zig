//! wl_signal + wl_listener: the observer primitive libwayland uses everywhere
//! for destroy/notify notifications.
//!
//! Mirrors libwayland's `struct wl_signal` and `struct wl_listener`
//! (wayland-server-core.h). A `Listener` is an intrusive list `Link` plus a
//! `notify` callback. A `Signal` owns a list of listeners; `emit` invokes each
//! listener's callback with the signal data.
//!
//! `emit` is removal-safe: a listener that removes itself (or is removed)
//! during the callback does not corrupt iteration and the remaining listeners
//! still fire. This matches libwayland's wl_signal_emit_mutable concern (it
//! caches the next link before invoking each callback).

const std = @import("std");
const Link = @import("list.zig").Link;

/// The notify callback. Receives the listener that fired (so the host struct
/// can be recovered via @fieldParentPtr) and the opaque signal data.
/// Mirrors wl_notify_func_t: void (*)(struct wl_listener *, void *data).
pub const NotifyFn = *const fn (listener: *Listener, data: ?*anyopaque) void;

/// One observer. Embed this in a host struct, set `notify`, then add it to a
/// signal with `signal.add(&listener)`. Mirrors struct wl_listener.
pub const Listener = struct {
    link: Link,
    notify: NotifyFn,

    /// Recover the host struct that embeds this listener at field `field`.
    pub fn container(self: *Listener, comptime Host: type, comptime field: []const u8) *Host {
        return @fieldParentPtr(field, self);
    }
};

/// A signal: a list of listeners. Mirrors struct wl_signal.
pub const Signal = struct {
    listener_list: Link,

    /// Initialize an empty signal. Mirrors wl_signal_init.
    pub fn init(self: *Signal) void {
        self.listener_list.init();
    }

    /// Register a listener (appended at the tail, so listeners fire in the
    /// order they were added). Mirrors wl_signal_add.
    pub fn add(self: *Signal, listener: *Listener) void {
        self.listener_list.append(&listener.link);
    }

    /// Return the registered listener whose `notify` equals `notify`, or null.
    /// Mirrors wl_signal_get.
    pub fn get(self: *Signal, notify: NotifyFn) ?*Listener {
        var it = self.listener_list.iterator(Listener, "link");
        while (it.next()) |l| {
            if (l.notify == notify) return l;
        }
        return null;
    }

    /// Fire every listener with `data`. Removal-safe: a listener may remove
    /// itself (or another listener later in the list) from within its
    /// callback. Mirrors wl_signal_emit / wl_signal_emit_mutable.
    pub fn emit(self: *Signal, data: ?*anyopaque) void {
        var it = self.listener_list.iterator(Listener, "link");
        while (it.next()) |l| {
            l.notify(l, data);
        }
    }
};

const Observer = struct {
    listener: Listener,
    fired: bool = false,
    last_value: u32 = 0,

    fn onNotify(listener: *Listener, data: ?*anyopaque) void {
        const self: *Observer = @fieldParentPtr("listener", listener);
        self.fired = true;
        if (data) |d| {
            const v: *const u32 = @ptrCast(@alignCast(d));
            self.last_value = v.*;
        }
    }
};

test "Signal emit fires all listeners with data" {
    var sig: Signal = undefined;
    sig.init();

    var a = Observer{ .listener = .{ .link = undefined, .notify = Observer.onNotify } };
    var b = Observer{ .listener = .{ .link = undefined, .notify = Observer.onNotify } };
    var c = Observer{ .listener = .{ .link = undefined, .notify = Observer.onNotify } };
    sig.add(&a.listener);
    sig.add(&b.listener);
    sig.add(&c.listener);

    var value: u32 = 99;
    sig.emit(&value);

    try std.testing.expect(a.fired and b.fired and c.fired);
    try std.testing.expectEqual(@as(u32, 99), a.last_value);
    try std.testing.expectEqual(@as(u32, 99), b.last_value);
    try std.testing.expectEqual(@as(u32, 99), c.last_value);
}

test "Signal get finds a listener by notify fn" {
    var sig: Signal = undefined;
    sig.init();
    var a = Observer{ .listener = .{ .link = undefined, .notify = Observer.onNotify } };
    sig.add(&a.listener);
    try std.testing.expect(sig.get(Observer.onNotify) == &a.listener);

    const other: NotifyFn = struct {
        fn f(_: *Listener, _: ?*anyopaque) void {}
    }.f;
    try std.testing.expect(sig.get(other) == null);
}

// A listener that removes itself from within its own callback.
const SelfRemover = struct {
    listener: Listener,
    fired: bool = false,

    fn onNotify(listener: *Listener, _: ?*anyopaque) void {
        const self: *SelfRemover = @fieldParentPtr("listener", listener);
        self.fired = true;
        self.listener.link.remove();
    }
};

test "Signal emit tolerates a listener removing itself mid-emit" {
    var sig: Signal = undefined;
    sig.init();

    var a = Observer{ .listener = .{ .link = undefined, .notify = Observer.onNotify } };
    var remover = SelfRemover{ .listener = .{ .link = undefined, .notify = SelfRemover.onNotify } };
    var c = Observer{ .listener = .{ .link = undefined, .notify = Observer.onNotify } };

    sig.add(&a.listener);
    sig.add(&remover.listener); // removes itself when fired
    sig.add(&c.listener);

    var value: u32 = 7;
    sig.emit(&value);

    // The self-removing listener fired, did not crash, and the others fired.
    try std.testing.expect(remover.fired);
    try std.testing.expect(a.fired and c.fired);
    try std.testing.expectEqual(@as(u32, 7), c.last_value);

    // remover is gone; a and c remain. A second emit must not touch remover.
    remover.fired = false;
    a.fired = false;
    c.fired = false;
    sig.emit(&value);
    try std.testing.expect(!remover.fired);
    try std.testing.expect(a.fired and c.fired);
    try std.testing.expectEqual(@as(usize, 2), sig.listener_list.length());
}
