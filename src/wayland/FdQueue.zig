//! A small FIFO queue of received file descriptors (SCM_RIGHTS out-of-band fds).
//!
//! Shared by the client connection layer (`client.Connection`) and the server
//! connection layer (`connection.Connection`) so `argument.demarshal` can pull an
//! incoming fd from either through one concrete type, instead of being tied to a
//! single Connection struct. libwayland caps a single message's SCM_RIGHTS set at
//! MAX_FDS_OUT = 28, so that is the capacity here.

const std = @import("std");
const FdQueue = @This();

pub const capacity: usize = 28;

fds: [capacity]i32 = undefined,
count: usize = 0,

/// Queue a received fd in arrival order. On overflow the fd is closed rather
/// than leaked (a conformant peer never overflows one message's fd set).
pub fn push(self: *FdQueue, fd: i32) void {
    if (self.count >= self.fds.len) {
        _ = std.posix.system.close(fd);
        return;
    }
    self.fds[self.count] = fd;
    self.count += 1;
}

/// Pop the oldest queued fd (FIFO), or null if empty. The caller owns the fd
/// and must close it.
pub fn takeFd(self: *FdQueue) ?i32 {
    if (self.count == 0) return null;
    const fd = self.fds[0];
    self.count -= 1;
    for (0..self.count) |i| self.fds[i] = self.fds[i + 1];
    return fd;
}

/// Close and drop every queued fd (teardown).
pub fn closeAll(self: *FdQueue) void {
    for (self.fds[0..self.count]) |fd| _ = std.posix.system.close(fd);
    self.count = 0;
}

test "FdQueue is FIFO and reports empty" {
    var q = FdQueue{};
    try std.testing.expect(q.takeFd() == null);
    q.push(10);
    q.push(11);
    try std.testing.expectEqual(@as(?i32, 10), q.takeFd());
    try std.testing.expectEqual(@as(?i32, 11), q.takeFd());
    try std.testing.expect(q.takeFd() == null);
}
