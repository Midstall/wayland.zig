//! wl_event_loop equivalent: an epoll-based event loop.
//!
//! Mirrors libwayland's `struct wl_event_loop` (src/event-loop.c,
//! wayland-server-core.h). A single epoll fd multiplexes file-descriptor
//! sources, timers (timerfd), and signals (signalfd); idle sources run once at
//! the start of the next dispatch. Sources are tracked with the intrusive
//! Link/list primitive so removal during dispatch is safe (removed sources are
//! deferred to a destroy list and freed after the ready sources are processed,
//! like libwayland).
//!
//! Raw Linux syscalls via std.os.linux; errno via std.posix.errno. Zig 0.16.
//!
//! API parity with libwayland:
//!   EventLoop.create / destroy
//!   addFd(fd, mask, callback, data) -> *EventSource ; updateFd(source, mask)
//!   addTimer(callback, data) -> *EventSource ; timerUpdate(source, ms)
//!   addSignal(signum, callback, data) -> *EventSource
//!   addIdle(callback, data) -> *EventSource
//!   eventSourceRemove(source)
//!   dispatch(timeout_ms) ; dispatchIdle() ; getFd()

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Link = @import("list.zig").Link;

/// Event mask bitflags. Values match libwayland's WL_EVENT_* exactly.
pub const READABLE: u32 = 0x01;
pub const WRITABLE: u32 = 0x02;
pub const HANGUP: u32 = 0x04;
pub const ERROR: u32 = 0x08;

/// fd callback. Returns the count of work done (>0 means it did work).
/// Mirrors wl_event_loop_fd_func_t: int (*)(int fd, uint32_t mask, void *data).
pub const FdFn = *const fn (fd: i32, mask: u32, data: ?*anyopaque) callconv(.c) c_int;
/// timer callback. Mirrors wl_event_loop_timer_func_t: int (*)(void *data).
pub const TimerFn = *const fn (data: ?*anyopaque) callconv(.c) c_int;
/// signal callback. Mirrors wl_event_loop_signal_func_t: int (*)(int, void *).
pub const SignalFn = *const fn (signal_number: i32, data: ?*anyopaque) callconv(.c) c_int;
/// idle callback. Mirrors wl_event_loop_idle_func_t: void (*)(void *data).
pub const IdleFn = *const fn (data: ?*anyopaque) callconv(.c) void;

pub const EventLoopError = error{
    EpollCreateFailed,
    EpollCtlFailed,
    TimerfdCreateFailed,
    SignalfdCreateFailed,
    OutOfMemory,
};

const SourceKind = enum { fd, timer, signal, idle };

/// One event source. Allocated by the loop, returned to the caller as an opaque
/// handle, and freed by the loop (via the destroy list on removal, or on
/// destroy). Mirrors `struct wl_event_source` plus its per-kind subtypes.
pub const EventSource = struct {
    loop: *EventLoop,
    link: Link,
    kind: SourceKind,
    /// The fd registered in epoll, or -1 for idle sources (and after removal).
    fd: i32,
    data: ?*anyopaque,

    // Per-kind callback + state (a tagged-union-by-`kind` payload).
    fd_fn: FdFn = undefined,
    timer_fn: TimerFn = undefined,
    signal_fn: SignalFn = undefined,
    idle_fn: IdleFn = undefined,
    signal_number: i32 = 0,

    fn dispatch(self: *EventSource, events: u32) c_int {
        switch (self.kind) {
            .fd => {
                var mask: u32 = 0;
                if (events & linux.EPOLL.IN != 0) mask |= READABLE;
                if (events & linux.EPOLL.OUT != 0) mask |= WRITABLE;
                if (events & linux.EPOLL.HUP != 0) mask |= HANGUP;
                if (events & linux.EPOLL.ERR != 0) mask |= ERROR;
                return self.fd_fn(self.fd, mask, self.data);
            },
            .timer => {
                var expires: u64 = 0;
                _ = posix.read(self.fd, std.mem.asBytes(&expires)) catch 0;
                return self.timer_fn(self.data);
            },
            .signal => {
                var info: linux.signalfd_siginfo = undefined;
                _ = posix.read(self.fd, std.mem.asBytes(&info)) catch 0;
                return self.signal_fn(self.signal_number, self.data);
            },
            .idle => return 0,
        }
    }
};

pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    epoll_fd: i32,
    idle_list: Link,
    destroy_list: Link,

    /// Create an epoll-backed event loop. Mirrors wl_event_loop_create.
    pub fn create(allocator: std.mem.Allocator) EventLoopError!*EventLoop {
        const rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (posix.errno(rc) != .SUCCESS) return error.EpollCreateFailed;
        const epoll_fd: i32 = @intCast(rc);

        const loop = allocator.create(EventLoop) catch {
            _ = linux.close(epoll_fd);
            return error.OutOfMemory;
        };
        loop.* = .{
            .allocator = allocator,
            .epoll_fd = epoll_fd,
            .idle_list = undefined,
            .destroy_list = undefined,
        };
        loop.idle_list.init();
        loop.destroy_list.init();
        return loop;
    }

    /// Destroy the loop, freeing any pending (removed) sources and the epoll fd.
    /// Mirrors wl_event_loop_destroy. Note: still-registered sources are the
    /// caller's responsibility, as in libwayland.
    pub fn destroy(self: *EventLoop) void {
        self.processDestroyList();
        // Free any idle sources that were never dispatched.
        var it = self.idle_list.iterator(EventSource, "link");
        while (it.next()) |src| {
            src.link.remove();
            self.allocator.destroy(src);
        }
        _ = linux.close(self.epoll_fd);
        const a = self.allocator;
        a.destroy(self);
    }

    /// The epoll fd, so a compositor can embed this loop in another poll set.
    /// Mirrors wl_event_loop_get_fd.
    pub fn getFd(self: *const EventLoop) i32 {
        return self.epoll_fd;
    }

    fn epollMask(mask: u32) u32 {
        var ev: u32 = 0;
        if (mask & READABLE != 0) ev |= linux.EPOLL.IN;
        if (mask & WRITABLE != 0) ev |= linux.EPOLL.OUT;
        return ev;
    }

    fn epollAdd(self: *EventLoop, source: *EventSource, mask: u32) EventLoopError!void {
        var ev = linux.epoll_event{
            .events = epollMask(mask),
            .data = .{ .ptr = @intFromPtr(source) },
        };
        const rc = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, source.fd, &ev);
        if (posix.errno(rc) != .SUCCESS) return error.EpollCtlFailed;
    }

    /// Add a file-descriptor source. The loop does not take ownership of `fd`
    /// (it is not duplicated; the caller keeps ownership). Mirrors
    /// wl_event_loop_add_fd.
    pub fn addFd(
        self: *EventLoop,
        fd: i32,
        mask: u32,
        callback: FdFn,
        data: ?*anyopaque,
    ) EventLoopError!*EventSource {
        const source = try self.allocator.create(EventSource);
        errdefer self.allocator.destroy(source);
        source.* = .{
            .loop = self,
            .link = undefined,
            .kind = .fd,
            .fd = fd,
            .data = data,
            .fd_fn = callback,
        };
        source.link.init();
        try self.epollAdd(source, mask);
        return source;
    }

    /// Change the event mask of an fd source. Mirrors wl_event_source_fd_update.
    pub fn updateFd(self: *EventLoop, source: *EventSource, mask: u32) EventLoopError!void {
        var ev = linux.epoll_event{
            .events = epollMask(mask),
            .data = .{ .ptr = @intFromPtr(source) },
        };
        const rc = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_MOD, source.fd, &ev);
        if (posix.errno(rc) != .SUCCESS) return error.EpollCtlFailed;
    }

    /// Add a timer source (disarmed). Arm it with `timerUpdate`. Mirrors
    /// wl_event_loop_add_timer.
    pub fn addTimer(
        self: *EventLoop,
        callback: TimerFn,
        data: ?*anyopaque,
    ) EventLoopError!*EventSource {
        const rc = linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true });
        if (posix.errno(rc) != .SUCCESS) return error.TimerfdCreateFailed;
        const fd: i32 = @intCast(rc);
        errdefer _ = linux.close(fd);

        const source = try self.allocator.create(EventSource);
        errdefer self.allocator.destroy(source);
        source.* = .{
            .loop = self,
            .link = undefined,
            .kind = .timer,
            .fd = fd,
            .data = data,
            .timer_fn = callback,
        };
        source.link.init();
        try self.epollAdd(source, READABLE);
        return source;
    }

    /// Arm (or, with 0, disarm) a timer source to fire once after `ms`
    /// milliseconds. Mirrors wl_event_source_timer_update.
    pub fn timerUpdate(_: *EventLoop, source: *EventSource, ms: u64) EventLoopError!void {
        const its = linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{
                .sec = @intCast(ms / 1000),
                .nsec = @intCast((ms % 1000) * 1000 * 1000),
            },
        };
        const rc = linux.timerfd_settime(source.fd, .{}, &its, null);
        if (posix.errno(rc) != .SUCCESS) return error.TimerfdCreateFailed;
    }

    /// Add a signal source. Blocks `signum` in the process signal mask and
    /// delivers it via signalfd. Mirrors wl_event_loop_add_signal.
    pub fn addSignal(
        self: *EventLoop,
        signum: i32,
        callback: SignalFn,
        data: ?*anyopaque,
    ) EventLoopError!*EventSource {
        var mask = linux.sigemptyset();
        linux.sigaddset(&mask, @enumFromInt(@as(u32, @intCast(signum))));
        const rc = linux.signalfd(-1, &mask, linux.SFD.CLOEXEC);
        if (posix.errno(rc) != .SUCCESS) return error.SignalfdCreateFailed;
        const fd: i32 = @intCast(rc);
        errdefer _ = linux.close(fd);
        _ = linux.sigprocmask(linux.SIG.BLOCK, &mask, null);

        const source = try self.allocator.create(EventSource);
        errdefer self.allocator.destroy(source);
        source.* = .{
            .loop = self,
            .link = undefined,
            .kind = .signal,
            .fd = fd,
            .data = data,
            .signal_fn = callback,
            .signal_number = signum,
        };
        source.link.init();
        try self.epollAdd(source, READABLE);
        return source;
    }

    /// Add an idle source: runs once, at the start of the next dispatch (then
    /// auto-removes). Mirrors wl_event_loop_add_idle.
    pub fn addIdle(
        self: *EventLoop,
        callback: IdleFn,
        data: ?*anyopaque,
    ) EventLoopError!*EventSource {
        const source = try self.allocator.create(EventSource);
        source.* = .{
            .loop = self,
            .link = undefined,
            .kind = .idle,
            .fd = -1,
            .data = data,
            .idle_fn = callback,
        };
        source.link.init();
        self.idle_list.append(&source.link);
        return source;
    }

    /// Remove a source from the loop. The fd (for fd/timer/signal sources) is
    /// removed from epoll and closed (timer/signal own their fd; an fd source's
    /// fd was not duplicated so closing it returns it to the caller's control
    /// being gone). The source struct is deferred to the destroy list and freed
    /// after the current dispatch. Mirrors wl_event_source_remove.
    pub fn eventSourceRemove(self: *EventLoop, source: *EventSource) void {
        if (source.fd >= 0) {
            _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, source.fd, null);
            // timer and signal sources own their fd; fd sources were handed an
            // fd we did not dup, so closing here matches libwayland (which
            // dup'd; we keep parity on the "stop delivering" guarantee).
            if (source.kind == .timer or source.kind == .signal) {
                _ = linux.close(source.fd);
            }
            source.fd = -1;
        }
        source.link.remove();
        self.destroy_list.append(&source.link);
    }

    fn processDestroyList(self: *EventLoop) void {
        var it = self.destroy_list.iterator(EventSource, "link");
        while (it.next()) |src| {
            self.allocator.destroy(src);
        }
        self.destroy_list.init();
    }

    /// Run all currently-queued idle sources (each fires once, then removed).
    /// Mirrors wl_event_loop_dispatch_idle / dispatch_idle_sources.
    pub fn dispatchIdle(self: *EventLoop) void {
        while (!self.idle_list.empty()) {
            const src: *EventSource = @fieldParentPtr("link", self.idle_list.next);
            src.idle_fn(src.data);
            self.eventSourceRemove(src);
        }
        self.processDestroyList();
    }

    /// One iteration of the loop. Runs pending idle sources, waits up to
    /// `timeout_ms` (negative blocks forever, 0 returns immediately) for ready
    /// fd/timer/signal sources, dispatches them, then frees removed sources.
    /// Returns 0 on success or error. Mirrors wl_event_loop_dispatch.
    pub fn dispatch(self: *EventLoop, timeout_ms: i32) EventLoopError!void {
        self.dispatchIdle();

        var events: [32]linux.epoll_event = undefined;
        const rc = linux.epoll_wait(self.epoll_fd, &events, events.len, timeout_ms);
        if (posix.errno(rc) != .SUCCESS) {
            // EINTR is benign: just return as if nothing was ready.
            if (posix.errno(rc) == .INTR) return;
            return error.EpollCtlFailed;
        }
        const count: usize = @intCast(rc);
        for (events[0..count]) |ev| {
            const source: *EventSource = @ptrFromInt(ev.data.ptr);
            // A source removed earlier in this same batch has fd == -1.
            if (source.fd != -1) {
                _ = source.dispatch(ev.events);
            }
        }
        self.processDestroyList();
    }
};

const testing = std.testing;

fn makeEventfd() i32 {
    const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    return @intCast(rc);
}

const FdCtx = struct {
    fired: u32 = 0,
    last_mask: u32 = 0,
    fn cb(fd: i32, mask: u32, data: ?*anyopaque) callconv(.c) c_int {
        const self: *FdCtx = @ptrCast(@alignCast(data.?));
        self.fired += 1;
        self.last_mask = mask;
        // Drain the eventfd so it stops being readable.
        var buf: u64 = 0;
        _ = posix.read(fd, std.mem.asBytes(&buf)) catch {};
        return 1;
    }
};

test "EventLoop addFd: eventfd write triggers callback" {
    const loop = try EventLoop.create(testing.allocator);
    defer loop.destroy();

    const efd = makeEventfd();
    defer _ = linux.close(efd);

    var ctx = FdCtx{};
    const src = try loop.addFd(efd, READABLE, FdCtx.cb, &ctx);

    // Nothing written yet: dispatch with 0 timeout does no fd work.
    try loop.dispatch(0);
    try testing.expectEqual(@as(u32, 0), ctx.fired);

    // Write to the eventfd, then dispatch -> the callback fires.
    var one: u64 = 1;
    _ = linux.write(efd, std.mem.asBytes(&one), @sizeOf(u64));
    try loop.dispatch(100);
    try testing.expectEqual(@as(u32, 1), ctx.fired);
    try testing.expect(ctx.last_mask & READABLE != 0);

    loop.eventSourceRemove(src);
}

test "EventLoop getFd returns a valid epoll fd" {
    const loop = try EventLoop.create(testing.allocator);
    defer loop.destroy();
    try testing.expect(loop.getFd() >= 0);
    // It is a real, distinct fd we can poll on.
    try testing.expect(loop.getFd() != 0);
}

const TimerCtx = struct {
    fired: u32 = 0,
    fn cb(data: ?*anyopaque) callconv(.c) c_int {
        const self: *TimerCtx = @ptrCast(@alignCast(data.?));
        self.fired += 1;
        return 1;
    }
};

test "EventLoop addTimer fires after the delay" {
    const loop = try EventLoop.create(testing.allocator);
    defer loop.destroy();

    var ctx = TimerCtx{};
    const src = try loop.addTimer(TimerCtx.cb, &ctx);
    try loop.timerUpdate(src, 10); // ~10ms

    // Loop dispatching until the timer fires (bounded by a generous wall clock).
    var iterations: u32 = 0;
    while (ctx.fired == 0 and iterations < 100) : (iterations += 1) {
        try loop.dispatch(50);
    }
    try testing.expectEqual(@as(u32, 1), ctx.fired);

    loop.eventSourceRemove(src);
}

const IdleCtx = struct {
    runs: u32 = 0,
    fn cb(data: ?*anyopaque) callconv(.c) void {
        const self: *IdleCtx = @ptrCast(@alignCast(data.?));
        self.runs += 1;
    }
};

test "EventLoop addIdle runs exactly once on the next dispatch" {
    const loop = try EventLoop.create(testing.allocator);
    defer loop.destroy();

    var ctx = IdleCtx{};
    _ = try loop.addIdle(IdleCtx.cb, &ctx);
    try testing.expectEqual(@as(u32, 0), ctx.runs);

    // First dispatch runs the idle once.
    try loop.dispatch(0);
    try testing.expectEqual(@as(u32, 1), ctx.runs);

    // Subsequent dispatches do not run it again.
    try loop.dispatch(0);
    try loop.dispatch(0);
    try testing.expectEqual(@as(u32, 1), ctx.runs);
}

test "EventLoop eventSourceRemove stops further callbacks" {
    const loop = try EventLoop.create(testing.allocator);
    defer loop.destroy();

    const efd = makeEventfd();
    defer _ = linux.close(efd);

    var ctx = FdCtx{};
    const src = try loop.addFd(efd, READABLE, FdCtx.cb, &ctx);

    var one: u64 = 1;
    _ = linux.write(efd, std.mem.asBytes(&one), @sizeOf(u64));
    try loop.dispatch(100);
    try testing.expectEqual(@as(u32, 1), ctx.fired);

    // Remove the source, then make the eventfd readable again.
    loop.eventSourceRemove(src);
    _ = linux.write(efd, std.mem.asBytes(&one), @sizeOf(u64));
    try loop.dispatch(20);
    // Still 1: the removed source did not fire.
    try testing.expectEqual(@as(u32, 1), ctx.fired);
}
