//! wl_connection equivalent: the buffered wire connection for one socket.
//!
//! Mirrors libwayland's `struct wl_connection` (src/connection.c). It owns a
//! single connected AF_UNIX SOCK_STREAM fd and buffers bytes in both
//! directions, plus a queue of file descriptors that travel out-of-band over
//! SCM_RIGHTS ancillary data.
//!
//! Message framing is the Wayland wire format: an 8-byte header
//! (object id u32, then (size << 16) | opcode as a u32) followed by the
//! argument words. `read` pulls bytes via recvmsg (queuing any incoming fds),
//! `flush` pushes buffered out-bytes via sendmsg (attaching queued out-fds).
//!
//! Raw Linux syscalls via std.os.linux, errno via std.posix.errno. Zig 0.16
//! (std.os.linux.close, not std.posix.close).

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

/// Ring/staging buffer sizes. libwayland uses 4096-byte data buffers and a
/// 2KiB fd buffer; we match the data size and cap the fd queue at 28 (the
/// SCM_RIGHTS limit per message in libwayland is MAX_FDS_OUT = 28).
const BUFFER_SIZE: usize = 4096;
const MAX_FDS_OUT: usize = 28;

pub const ConnectionError = error{
    Closed,
    BrokenPipe,
    OutOfMemory,
    BufferFull,
    SendFailed,
    RecvFailed,
};

/// A simple byte staging buffer (not a true ring: a head/tail window over a
/// fixed array, compacted when it would overflow). Sufficient and matches the
/// "data buffered until flush / until a full message is present" contract.
const ByteBuffer = struct {
    data: [BUFFER_SIZE]u8 = undefined,
    head: usize = 0,
    tail: usize = 0,

    fn len(self: *const ByteBuffer) usize {
        return self.tail - self.head;
    }

    fn space(self: *const ByteBuffer) usize {
        // Compact-on-demand means the usable space is the whole buffer minus
        // what is currently live.
        return BUFFER_SIZE - self.len();
    }

    /// Drop consumed bytes so the live window starts at 0.
    fn compact(self: *ByteBuffer) void {
        if (self.head == 0) return;
        const n = self.len();
        if (n > 0) std.mem.copyForwards(u8, self.data[0..n], self.data[self.head..self.tail]);
        self.head = 0;
        self.tail = n;
    }

    /// Append bytes, compacting first if needed. Errors if they cannot fit.
    fn append(self: *ByteBuffer, bytes: []const u8) ConnectionError!void {
        if (bytes.len > self.space()) return error.BufferFull;
        if (self.tail + bytes.len > BUFFER_SIZE) self.compact();
        @memcpy(self.data[self.tail .. self.tail + bytes.len], bytes);
        self.tail += bytes.len;
    }

    /// The live bytes, as a slice.
    fn slice(self: *ByteBuffer) []const u8 {
        return self.data[self.head..self.tail];
    }

    /// Advance the head past `n` consumed bytes.
    fn consume(self: *ByteBuffer, n: usize) void {
        self.head += n;
        if (self.head == self.tail) {
            self.head = 0;
            self.tail = 0;
        }
    }
};

/// One buffered wire connection over a connected AF_UNIX socket fd.
pub const Connection = struct {
    fd: i32,
    in: ByteBuffer = .{},
    out: ByteBuffer = .{},
    /// Incoming fds received via SCM_RIGHTS, awaiting consumption by a handler.
    fds_in: [MAX_FDS_OUT]i32 = undefined,
    fds_in_head: usize = 0,
    fds_in_tail: usize = 0,
    /// Outgoing fds to attach to the next flush.
    fds_out: [MAX_FDS_OUT]i32 = undefined,
    fds_out_count: usize = 0,

    /// Wrap an already-connected, nonblocking socket fd. The Connection does
    /// not own the fd's lifetime beyond what `close` does.
    pub fn init(fd: i32) Connection {
        return .{ .fd = fd };
    }

    /// Close the connection's fd. Any queued, un-consumed incoming fds are
    /// closed too (they would otherwise leak). Queued outgoing fds are the
    /// caller's responsibility to have flushed.
    pub fn close(self: *Connection) void {
        while (self.fds_in_head < self.fds_in_tail) : (self.fds_in_head += 1) {
            _ = linux.close(self.fds_in[self.fds_in_head]);
        }
        self.fds_in_head = 0;
        self.fds_in_tail = 0;
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
    }

    /// Bytes currently buffered for reading (already pulled off the socket).
    pub fn pendingIn(self: *const Connection) usize {
        return self.in.len();
    }

    /// Bytes currently buffered for writing (awaiting flush).
    pub fn pendingOut(self: *const Connection) usize {
        return self.out.len();
    }

    /// Take the next received fd from the incoming queue, or null if none.
    pub fn takeFd(self: *Connection) ?i32 {
        if (self.fds_in_head >= self.fds_in_tail) return null;
        const fd = self.fds_in[self.fds_in_head];
        self.fds_in_head += 1;
        if (self.fds_in_head == self.fds_in_tail) {
            self.fds_in_head = 0;
            self.fds_in_tail = 0;
        }
        return fd;
    }

    /// Pull whatever is available off the socket into the in-buffer, collecting
    /// any SCM_RIGHTS fds into the incoming fd queue. Returns the number of
    /// data bytes read. 0 means the peer closed (orderly EOF). EAGAIN is
    /// reported as 0 bytes with no error (the socket is nonblocking and in the
    /// event loop, so we will be told again when more arrives).
    pub fn read(self: *Connection) ConnectionError!usize {
        self.in.compact();
        const avail = self.in.space();
        if (avail == 0) return 0;

        var iov = posix.iovec{
            .base = self.in.data[self.in.tail..].ptr,
            .len = avail,
        };

        // Room for a control buffer holding several fds.
        var cmsg_buf: [256]u8 align(8) = std.mem.zeroes([256]u8);

        var msg = linux.msghdr{
            .name = null,
            .namelen = 0,
            .iov = @ptrCast(&iov),
            .iovlen = 1,
            .control = &cmsg_buf,
            .controllen = cmsg_buf.len,
            .flags = 0,
        };

        // MSG_CMSG_CLOEXEC = 0x40000000, MSG_DONTWAIT = 0x40.
        const MSG_CMSG_CLOEXEC: u32 = 0x40000000;
        const MSG_DONTWAIT: u32 = 0x40;
        const rc = linux.recvmsg(self.fd, &msg, MSG_CMSG_CLOEXEC | MSG_DONTWAIT);
        const e = posix.errno(rc);
        if (e != .SUCCESS) {
            if (e == .AGAIN or e == .INTR) return 0;
            return error.RecvFailed;
        }
        const n: usize = @intCast(rc);
        if (n == 0) return 0; // orderly peer close

        self.in.tail += n;
        self.collectFds(&msg);
        return n;
    }

    /// Scan a recvmsg result's control messages for SCM_RIGHTS fds and queue
    /// them. Truncated control data (MSG_CTRUNC) is tolerated by only walking
    /// the bytes the kernel actually wrote (`msg.controllen`).
    fn collectFds(self: *Connection, msg: *const linux.msghdr) void {
        const Cmsghdr = linux.cmsghdr;
        const ctrl = msg.control orelse return;
        var offset: usize = 0;
        const total = msg.controllen;
        const base: [*]const u8 = @ptrCast(ctrl);
        while (offset + @sizeOf(Cmsghdr) <= total) {
            const cmsg: *const Cmsghdr = @ptrCast(@alignCast(base + offset));
            const cmsg_len = cmsg.len;
            if (cmsg_len < @sizeOf(Cmsghdr) or offset + cmsg_len > total) break;
            if (cmsg.level == posix.SOL.SOCKET and cmsg.type == posix.SCM.RIGHTS) {
                const data_off = offset + cmsgAlign(@sizeOf(Cmsghdr));
                const data_bytes = cmsg_len - cmsgAlign(@sizeOf(Cmsghdr));
                const count = data_bytes / @sizeOf(i32);
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const fd_ptr: *const i32 = @ptrCast(@alignCast(base + data_off + i * @sizeOf(i32)));
                    self.queueInFd(fd_ptr.*);
                }
            }
            offset += cmsgAlign(cmsg_len);
        }
    }

    fn queueInFd(self: *Connection, fd: i32) void {
        if (self.fds_in_tail >= MAX_FDS_OUT) {
            // No room: close it rather than leak (matches the "drop on
            // overflow" defensive posture; a real client never overflows).
            _ = linux.close(fd);
            return;
        }
        self.fds_in[self.fds_in_tail] = fd;
        self.fds_in_tail += 1;
    }

    /// Copy out a complete message starting at the in-buffer head into `out`,
    /// without consuming it. Returns the message size, or null if a full
    /// message is not yet buffered. `out` must be at least the message size.
    pub fn peekMessage(self: *Connection, out: []u8) ConnectionError!?usize {
        const live = self.in.slice();
        if (live.len < 8) return null;
        const word1 = std.mem.readInt(u32, live[4..8], .little);
        const size: usize = word1 >> 16;
        if (size < 8) return error.RecvFailed; // malformed
        if (live.len < size) return null;
        if (out.len < size) return error.BufferFull;
        @memcpy(out[0..size], live[0..size]);
        return size;
    }

    /// Consume `n` bytes from the front of the in-buffer (after peekMessage).
    pub fn consume(self: *Connection, n: usize) void {
        self.in.consume(n);
    }

    /// Queue a full wire message (header + args) for sending, plus any fds to
    /// attach. The fds are sent with the NEXT flush. Bytes are buffered; call
    /// `flush` to push them.
    pub fn queueMessage(self: *Connection, bytes: []const u8, fds: []const i32) ConnectionError!void {
        if (self.fds_out_count + fds.len > MAX_FDS_OUT) {
            // Force a flush to drain the current fd batch first.
            try self.flush();
            if (fds.len > MAX_FDS_OUT) return error.BufferFull;
        }
        if (bytes.len > self.out.space()) {
            try self.flush();
        }
        try self.out.append(bytes);
        for (fds) |fd| {
            self.fds_out[self.fds_out_count] = fd;
            self.fds_out_count += 1;
        }
    }

    /// Flush buffered out-bytes (and attached fds) to the socket. Handles
    /// partial writes and EAGAIN: on EAGAIN the unsent remainder stays buffered
    /// and the call returns (the event loop will signal WRITABLE later). The
    /// attached fds are sent with the first sendmsg that carries data.
    pub fn flush(self: *Connection) ConnectionError!void {
        while (self.out.len() > 0) {
            const live = self.out.slice();

            var iov = posix.iovec_const{ .base = live.ptr, .len = live.len };

            var cmsg_buf: [256]u8 align(8) = std.mem.zeroes([256]u8);
            var controllen: usize = 0;
            var control_ptr: ?*const anyopaque = null;
            if (self.fds_out_count > 0) {
                const Cmsghdr = linux.cmsghdr;
                const data_bytes = self.fds_out_count * @sizeOf(i32);
                const cmsg_len = cmsgAlign(@sizeOf(Cmsghdr)) + data_bytes;
                const cmsg: *Cmsghdr = @ptrCast(@alignCast(&cmsg_buf));
                cmsg.len = cmsg_len;
                cmsg.level = posix.SOL.SOCKET;
                cmsg.type = posix.SCM.RIGHTS;
                const data_off = cmsgAlign(@sizeOf(Cmsghdr));
                var i: usize = 0;
                while (i < self.fds_out_count) : (i += 1) {
                    const fd_ptr: *i32 = @ptrCast(@alignCast(cmsg_buf[data_off + i * @sizeOf(i32) ..].ptr));
                    fd_ptr.* = self.fds_out[i];
                }
                controllen = cmsg_len;
                control_ptr = &cmsg_buf;
            }

            const msg = linux.msghdr_const{
                .name = null,
                .namelen = 0,
                .iov = @ptrCast(&iov),
                .iovlen = 1,
                .control = control_ptr,
                .controllen = controllen,
                .flags = 0,
            };

            // MSG_DONTWAIT | MSG_NOSIGNAL = 0x40 | 0x4000.
            const MSG_DONTWAIT: u32 = 0x40;
            const MSG_NOSIGNAL: u32 = 0x4000;
            const rc = linux.sendmsg(self.fd, &msg, MSG_DONTWAIT | MSG_NOSIGNAL);
            const e = posix.errno(rc);
            if (e != .SUCCESS) {
                if (e == .AGAIN or e == .INTR) return; // try again on next WRITABLE
                if (e == .PIPE or e == .CONNRESET) return error.BrokenPipe;
                return error.SendFailed;
            }
            const sent: usize = @intCast(rc);
            // fds (if any) were attached to this sendmsg; clear them now that
            // they have been transferred to the kernel.
            if (self.fds_out_count > 0) self.fds_out_count = 0;
            self.out.consume(sent);
            if (sent < live.len) {
                // Partial write: kernel buffer full. Leave the rest, retry later.
                return;
            }
        }
    }
};

/// Align a length up to the kernel's cmsg alignment (sizeof(usize)).
fn cmsgAlign(n: usize) usize {
    const a: usize = @sizeOf(usize);
    return (n + a - 1) & ~(a - 1);
}

const testing = std.testing;

fn socketpair() ![2]i32 {
    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0, &fds);
    if (posix.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    return fds;
}

test "connection: queue + flush + read frames a message" {
    const pair = try socketpair();
    var a = Connection.init(pair[0]);
    var b = Connection.init(pair[1]);
    defer a.close();
    defer b.close();

    // Build a small wire message by hand: object_id=1, opcode=1, size=12, one arg.
    var msg: [12]u8 = undefined;
    std.mem.writeInt(u32, msg[0..4], 1, .little);
    std.mem.writeInt(u32, msg[4..8], (@as(u32, 12) << 16) | 1, .little);
    std.mem.writeInt(u32, msg[8..12], 0xCAFE, .little);

    try a.queueMessage(&msg, &.{});
    try a.flush();
    try testing.expectEqual(@as(usize, 0), a.pendingOut());

    const n = try b.read();
    try testing.expectEqual(@as(usize, 12), n);

    var out: [64]u8 = undefined;
    const size = (try b.peekMessage(&out)).?;
    try testing.expectEqual(@as(usize, 12), size);
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[0..4], .little));
    try testing.expectEqual(@as(u32, 0xCAFE), std.mem.readInt(u32, out[8..12], .little));
    b.consume(size);
    // Nothing left.
    try testing.expect((try b.peekMessage(&out)) == null);
}

test "connection: SCM_RIGHTS fd round-trip" {
    const pair = try socketpair();
    var a = Connection.init(pair[0]);
    var b = Connection.init(pair[1]);
    defer a.close();
    defer b.close();

    // An eventfd to pass across.
    const efd: i32 = @intCast(linux.eventfd(0, linux.EFD.CLOEXEC));
    defer _ = linux.close(efd);

    var msg: [8]u8 = undefined;
    std.mem.writeInt(u32, msg[0..4], 2, .little);
    std.mem.writeInt(u32, msg[4..8], (@as(u32, 8) << 16) | 0, .little);

    try a.queueMessage(&msg, &.{efd});
    try a.flush();

    _ = try b.read();
    var out: [16]u8 = undefined;
    const size = (try b.peekMessage(&out)).?;
    try testing.expectEqual(@as(usize, 8), size);
    b.consume(size);

    const received = b.takeFd();
    try testing.expect(received != null);
    // The received fd is a NEW fd referencing the same eventfd; it must be valid
    // and distinct, then we own it.
    try testing.expect(received.? >= 0);
    try testing.expect(received.? != efd);
    _ = linux.close(received.?);
    try testing.expect(b.takeFd() == null);
}

test "connection: peek returns null until a full message is buffered" {
    const pair = try socketpair();
    var a = Connection.init(pair[0]);
    var b = Connection.init(pair[1]);
    defer a.close();
    defer b.close();

    // Send only 4 bytes of a header (less than the 8-byte minimum).
    const partial = [_]u8{ 1, 0, 0, 0 };
    var iov = posix.iovec_const{ .base = &partial, .len = partial.len };
    const m = linux.msghdr_const{ .name = null, .namelen = 0, .iov = @ptrCast(&iov), .iovlen = 1, .control = null, .controllen = 0, .flags = 0 };
    _ = linux.sendmsg(a.fd, &m, 0);

    _ = try b.read();
    var out: [16]u8 = undefined;
    try testing.expect((try b.peekMessage(&out)) == null);
}
