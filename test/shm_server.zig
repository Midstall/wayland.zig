//! Server-side wl_shm tests: drive the `Shm(Protocol)` helper over the
//! generated wl_shm/wl_shm_pool/wl_buffer bindings through a Client. A memfd is
//! handed across a socketpair via SCM_RIGHTS (the same way a client's
//! create_pool fd arrives), then create_buffer bounds/format checks are
//! asserted server-side.
//!
//! `wl` is the abstract runtime, `wlp` the generated wayland.xml bindings.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const wl = @import("wayland");
const wlp = @import("wayland_protocol");

const Display = wl.Display;
const Client = wl.server_client.Client;
const Object = wl.Object;
const Shm = wl.shm.Shm(wlp);

fn socketpair() ![2]i32 {
    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0, &fds);
    if (posix.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    return fds;
}

fn writeAll(fd: i32, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (posix.errno(rc) != .SUCCESS) return error.WriteFailed;
        off += @intCast(rc);
    }
}

fn readSome(fd: i32, buf: []u8) !usize {
    const rc = linux.read(fd, buf.ptr, buf.len);
    if (posix.errno(rc) != .SUCCESS) return error.ReadFailed;
    return @intCast(rc);
}

fn memfd(size: usize) !i32 {
    const fd = try posix.memfd_create("wayland-shm-it", 0);
    const rc = linux.ftruncate(fd, @intCast(size));
    if (posix.errno(rc) != .SUCCESS) return error.TruncateFailed;
    return fd;
}

/// Build one wire message: header (object_id, (size<<16)|opcode) + body words.
fn buildMessage(gpa: std.mem.Allocator, object_id: u32, opcode: u16, body: []const u32) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    const size: u32 = @intCast(8 + body.len * 4);
    var hdr: [8]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], object_id, .little);
    std.mem.writeInt(u32, hdr[4..8], (size << 16) | @as(u32, opcode), .little);
    try buf.appendSlice(gpa, &hdr);
    for (body) |word| {
        var w: [4]u8 = undefined;
        std.mem.writeInt(u32, &w, word, .little);
        try buf.appendSlice(gpa, &w);
    }
    return buf.toOwnedSlice(gpa);
}

/// Send create_pool(new_id, size) on the wl_shm resource with `fd` attached via
/// SCM_RIGHTS (the 'h' arg travels out-of-band, the same way a client sends it).
fn sendCreatePool(client_fd: i32, gpa: std.mem.Allocator, shm_id: u32, pool_id: u32, fd: i32, size: i32) !void {
    // create_pool signature is "nhi": only new_id(n) and size(i) are in the
    // byte stream; the fd(h) rides in ancillary data.
    const body = [_]u32{ pool_id, @bitCast(size) };
    const msg = try buildMessage(gpa, shm_id, 0, &body);
    defer gpa.free(msg);
    try wl.shm.sendFd(client_fd, msg, fd);
}

/// Drive the server: pull bytes off the client socket, drain + dispatch, flush.
fn pump(client: *Client) void {
    _ = client.conn.read() catch {};
    _ = client.drainMessages();
    client.flush() catch {};
}

const Setup = struct {
    d: *Display,
    shm: *Shm,
    client: *Client,
    client_fd: i32,
    shm_id: u32 = 3,

    fn deinit(self: *Setup) void {
        _ = linux.close(self.client_fd);
        // Destroy the display first so it reaps the client and fires the pool/
        // buffer destroy hooks while the shm helper is still alive, then free
        // the helper (safe after destroy: deinit uses its cached allocator).
        self.d.destroy();
        self.shm.deinit();
    }
};

/// Bring a Display + wl_shm global + a bound wl_shm resource up, returning the
/// raw client fd and the server-side ids. Does the get_registry + bind dance.
fn setup(gpa: std.mem.Allocator) !Setup {
    const d = try Display.create(gpa);
    const shm = try Shm.create(d);

    const pair = try socketpair();
    const client = try Client.create(d, pair[0]);
    const client_fd = pair[1];

    const registry_id: u32 = 2;
    const shm_id: u32 = 3;

    // get_registry(new_id) on wl_display (id 1, opcode 1).
    {
        const msg = try buildMessage(gpa, wl.server_client.DISPLAY_ID, 1, &.{registry_id});
        defer gpa.free(msg);
        try writeAll(client_fd, msg);
    }
    pump(client);

    // Read the advertised globals, find wl_shm's name.
    var rbuf: [4096]u8 = undefined;
    const n = try readSome(client_fd, &rbuf);
    const shm_name = try findGlobalName(rbuf[0..n], registry_id, "wl_shm");

    // wl_registry.bind(name, "wl_shm", version, new_id) -> opcode 0.
    {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);
        try appendU32(&body, gpa, shm_name);
        try appendString(&body, gpa, "wl_shm");
        try appendU32(&body, gpa, wlp.WlShm.version);
        try appendU32(&body, gpa, shm_id);
        const size: u32 = @intCast(8 + body.items.len);
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(gpa);
        try appendU32(&msg, gpa, registry_id);
        try appendU32(&msg, gpa, (size << 16) | 0);
        try msg.appendSlice(gpa, body.items);
        try writeAll(client_fd, msg.items);
    }
    pump(client);

    return .{ .d = d, .shm = shm, .client = client, .client_fd = client_fd, .shm_id = shm_id };
}

fn appendU32(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try buf.appendSlice(gpa, &b);
}

fn appendString(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try appendU32(buf, gpa, @intCast(s.len + 1));
    try buf.appendSlice(gpa, s);
    try buf.append(gpa, 0);
    const total = s.len + 1;
    const pad = (4 - (total % 4)) % 4;
    var i: usize = 0;
    while (i < pad) : (i += 1) try buf.append(gpa, 0);
}

fn findGlobalName(stream: []const u8, registry_id: u32, want: []const u8) !u32 {
    var off: usize = 0;
    while (off + 8 <= stream.len) {
        const obj = std.mem.readInt(u32, stream[off..][0..4], .little);
        const word1 = std.mem.readInt(u32, stream[off + 4 ..][0..4], .little);
        const size: u16 = @truncate(word1 >> 16);
        const opcode: u16 = @truncate(word1);
        if (size < 8 or off + size > stream.len) break;
        const bodyslice = stream[off + 8 .. off + size];
        if (obj == registry_id and opcode == 0) {
            const name = std.mem.readInt(u32, bodyslice[0..4], .little);
            const slen = std.mem.readInt(u32, bodyslice[4..8], .little);
            if (slen >= 1 and 8 + slen - 1 <= bodyslice.len) {
                const str = bodyslice[8 .. 8 + slen - 1];
                if (std.mem.eql(u8, str, want)) return name;
            }
        }
        off += size;
    }
    return error.GlobalNotFound;
}

test "wl_shm server: bind advertises argb8888 + xrgb8888 formats" {
    const gpa = std.testing.allocator;
    var s = try setup(gpa);
    defer s.deinit();

    // The bind sent format events for both default formats. Read them.
    var buf: [256]u8 = undefined;
    const n = try readSome(s.client_fd, &buf);

    // Walk the format events (object=shm_id, opcode=0, body=format u32).
    var off: usize = 0;
    var saw_argb = false;
    var saw_xrgb = false;
    while (off + 12 <= n) {
        const obj = std.mem.readInt(u32, buf[off..][0..4], .little);
        const word1 = std.mem.readInt(u32, buf[off + 4 ..][0..4], .little);
        const size: u16 = @truncate(word1 >> 16);
        const opcode: u16 = @truncate(word1);
        if (obj == s.shm_id and opcode == 0 and size == 12) {
            const fmt = std.mem.readInt(u32, buf[off + 8 ..][0..4], .little);
            if (fmt == 0) saw_argb = true;
            if (fmt == 1) saw_xrgb = true;
        }
        if (size < 8) break;
        off += size;
    }
    try std.testing.expect(saw_argb);
    try std.testing.expect(saw_xrgb);
}

test "wl_shm server: create_pool maps fd, create_buffer succeeds in bounds" {
    const gpa = std.testing.allocator;
    var s = try setup(gpa);
    defer s.deinit();

    const pool_size: usize = 4096;
    const fd = try memfd(pool_size);
    const pool_id: u32 = 4;
    try sendCreatePool(s.client_fd, gpa, s.shm_id, pool_id, fd, @intCast(pool_size));
    _ = linux.close(fd); // the server dup'd it via SCM_RIGHTS
    pump(s.client);

    // The pool resource now exists with a Pool attached.
    const pool_res = s.client.getObject(pool_id) orelse return error.NoPool;
    try std.testing.expectEqualStrings("wl_shm_pool", pool_res.iface.?.name);
    const pool: *wl.shm.Pool = @ptrCast(@alignCast(pool_res.user_data.?));
    try std.testing.expectEqual(pool_size, pool.size);
    try std.testing.expectEqual(@as(usize, 1), pool.refcount);

    // create_buffer(new_id, offset=0, w=16, h=16, stride=64, format=argb8888)
    // 16*4 = 64 = stride; 64*16 = 1024 <= 4096. Valid.
    const buffer_id: u32 = 5;
    {
        const body = [_]u32{ buffer_id, 0, 16, 16, 64, 0 };
        const msg = try buildMessage(gpa, pool_id, 0, &body); // create_buffer opcode 0
        defer gpa.free(msg);
        try writeAll(s.client_fd, msg);
    }
    pump(s.client);

    const buf_res = s.client.getObject(buffer_id) orelse return error.NoBuffer;
    try std.testing.expectEqualStrings("wl_buffer", buf_res.iface.?.name);
    // The pool now has 2 refs (pool resource + buffer).
    try std.testing.expectEqual(@as(usize, 2), pool.refcount);

    const buffer: *wl.shm.Buffer = @ptrCast(@alignCast(buf_res.user_data.?));
    try std.testing.expectEqual(@as(i32, 16), buffer.width);
    try std.testing.expectEqual(@as(usize, 1024), buffer.pixels().len);

    // The client is not in an error state.
    try std.testing.expect(!s.client.error_posted);
}

test "wl_shm server: create_buffer out of bounds posts a protocol error" {
    const gpa = std.testing.allocator;
    var s = try setup(gpa);
    defer s.deinit();

    const pool_size: usize = 4096;
    const fd = try memfd(pool_size);
    const pool_id: u32 = 4;
    try sendCreatePool(s.client_fd, gpa, s.shm_id, pool_id, fd, @intCast(pool_size));
    _ = linux.close(fd);
    pump(s.client);

    // stride*height = 256*256 = 65536 > 4096: out of bounds.
    const buffer_id: u32 = 5;
    {
        const body = [_]u32{ buffer_id, 0, 256, 256, 1024, 0 };
        const msg = try buildMessage(gpa, pool_id, 0, &body);
        defer gpa.free(msg);
        try writeAll(s.client_fd, msg);
    }
    pump(s.client);

    // The server posted wl_shm.error (invalid_stride) and marked the client
    // fatally errored; no wl_buffer was created.
    try std.testing.expect(s.client.error_posted);
    try std.testing.expect(s.client.getObject(buffer_id) == null);
}

test "wl_shm server: create_buffer with unadvertised format posts an error" {
    const gpa = std.testing.allocator;
    var s = try setup(gpa);
    defer s.deinit();

    const pool_size: usize = 4096;
    const fd = try memfd(pool_size);
    const pool_id: u32 = 4;
    try sendCreatePool(s.client_fd, gpa, s.shm_id, pool_id, fd, @intCast(pool_size));
    _ = linux.close(fd);
    pump(s.client);

    // format 0xDEADBEEF is not advertised.
    const buffer_id: u32 = 5;
    {
        const body = [_]u32{ buffer_id, 0, 16, 16, 64, 0xDEADBEEF };
        const msg = try buildMessage(gpa, pool_id, 0, &body);
        defer gpa.free(msg);
        try writeAll(s.client_fd, msg);
    }
    pump(s.client);

    try std.testing.expect(s.client.error_posted);
    try std.testing.expect(s.client.getObject(buffer_id) == null);
}
