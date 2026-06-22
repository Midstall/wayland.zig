//! Wayland server: the libwayland-server-parity layer.
//!
//! This is the event-loop driven server (raw epoll via the foundation's
//! EventLoop, not std.Io). The pieces:
//!   - Display  (wl_display): owns the event loop, the client + global lists,
//!     the serial counter, the listening socket(s). See display.zig.
//!   - Client   (wl_client): one buffered wire Connection over an accepted fd,
//!     the per-client object map, credentials, framing + routing. See
//!     server_client.zig.
//!   - Connection (wl_connection): the buffered byte/fd wire transport with
//!     SCM_RIGHTS fd passing. See connection.zig.
//!   - Object   (wl_resource): the per-object record the client map holds. See
//!     server_client.zig.
//!
//! The core wire-protocol primitives (Writer/Reader/WireError, Fixed) are
//! re-exported for marshalling.

const std = @import("std");

const display_mod = @import("display.zig");
const client_mod = @import("server_client.zig");
const connection_mod = @import("connection.zig");
const wire = @import("wire.zig");

// Core wire-protocol primitives.
pub const Fixed = @import("fixed.zig").Fixed;
pub const WireWriter = wire.Writer;
pub const WireReader = wire.Reader;
pub const WireError = wire.WireError;

// The server objects.
pub const Display = display_mod.Display;
pub const DisplayError = display_mod.DisplayError;

pub const Client = client_mod.Client;
pub const ClientError = client_mod.ClientError;
pub const Object = client_mod.Object;
pub const Resource = client_mod.Object; // wl_resource seed alias
pub const Credentials = client_mod.Credentials;
pub const DispatchFn = client_mod.DispatchFn;
pub const SERVER_ID_START = client_mod.SERVER_ID_START;
pub const DISPLAY_ID = client_mod.DISPLAY_ID;

pub const Connection = connection_mod.Connection;
pub const ConnectionError = connection_mod.ConnectionError;

const linux = std.os.linux;
const posix = std.posix;
const testing = std.testing;

const ClientCreatedObserver = struct {
    listener: @import("signal.zig").Listener,
    fired: bool = false,
    last_client: ?*Client = null,

    fn onCreated(listener: *@import("signal.zig").Listener, data: ?*anyopaque) void {
        const self: *ClientCreatedObserver = @fieldParentPtr("listener", listener);
        self.fired = true;
        self.last_client = @ptrCast(@alignCast(data.?));
    }
};

const ClientDestroyObserver = struct {
    listener: @import("signal.zig").Listener,
    fired: bool = false,

    fn onDestroy(listener: *@import("signal.zig").Listener, _: ?*anyopaque) void {
        const self: *ClientDestroyObserver = @fieldParentPtr("listener", listener);
        self.fired = true;
    }
};

/// Connect a raw AF_UNIX SOCK_STREAM client to `socket_path`. Returns the fd.
fn rawConnect(socket_path: []const u8) !i32 {
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (posix.errno(rc) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(rc);
    errdefer _ = linux.close(fd);

    var addr = linux.sockaddr.un{ .family = linux.AF.UNIX, .path = std.mem.zeroes([108]u8) };
    if (socket_path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..socket_path.len], socket_path);
    const addrlen: linux.socklen_t = @intCast(@sizeOf(linux.sa_family_t) + socket_path.len + 1);
    const crc = linux.connect(fd, @ptrCast(&addr), addrlen);
    if (posix.errno(crc) != .SUCCESS) return error.ConnectFailed;
    return fd;
}

/// Send a wl_display.get_registry (object 1, opcode 1) request carrying one
/// new_id argument over the raw client fd.
fn sendGetRegistry(fd: i32, new_id: u32) !void {
    var msg: [12]u8 = undefined;
    std.mem.writeInt(u32, msg[0..4], client_mod.DISPLAY_ID, .little); // object id 1
    std.mem.writeInt(u32, msg[4..8], (@as(u32, 12) << 16) | 1, .little); // size 12, opcode 1
    std.mem.writeInt(u32, msg[8..12], new_id, .little); // new_id arg
    const rc = linux.write(fd, &msg, msg.len);
    if (posix.errno(rc) != .SUCCESS) return error.WriteFailed;
}

test "server: client connect, get_registry route, clean disconnect" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];

    const d = try Display.create(testing.allocator);
    defer d.destroy();

    // Observe client creation.
    var created = ClientCreatedObserver{ .listener = .{ .link = undefined, .notify = ClientCreatedObserver.onCreated } };
    created.listener.link.init();
    d.client_created_signal.add(&created.listener);

    // Bind a socket in the temp dir.
    var name_buf: [16]u8 = undefined;
    const name = try d.addSocketAutoInDir(dir, &name_buf);

    // Build the full socket path for the raw client connect.
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ dir, name });

    // Connect a raw client.
    const cfd = try rawConnect(full_path);
    // Closed explicitly at the disconnect step below.

    // Drive the loop until the accept happens (bounded).
    var iters: u32 = 0;
    while (!created.fired and iters < 50) : (iters += 1) {
        try d.loop.dispatch(20);
    }
    try testing.expect(created.fired);
    try testing.expect(created.last_client != null);
    const client = created.last_client.?;

    // The client is in the display's list.
    try testing.expect(!d.client_list.empty());
    try testing.expectEqual(@as(usize, 1), d.client_list.length());

    // credentials() returns this process's uid.
    try testing.expectEqual(linux.getuid(), client.credentials().uid);

    // The implicit wl_display (id 1) is in the client's object map.
    try testing.expect(client.getObject(client_mod.DISPLAY_ID) != null);

    // Attach a destroy observer now that we have the client.
    var destroyed = ClientDestroyObserver{ .listener = .{ .link = undefined, .notify = ClientDestroyObserver.onDestroy } };
    destroyed.listener.link.init();
    client.destroy_signal.add(&destroyed.listener);

    // The client sends wl_display.get_registry with new_id = 2.
    try sendGetRegistry(cfd, 2);

    // Drive the loop until the server routes it (the new id appears in the map).
    iters = 0;
    while (client.getObject(2) == null and iters < 50) : (iters += 1) {
        try d.loop.dispatch(20);
    }
    try testing.expect(client.getObject(2) != null);
    try testing.expectEqualStrings("wl_registry", client.getObject(2).?.interface_name);

    // Close the client socket; drive the loop; the client destroy signal fires
    // and it leaves the display's list.
    _ = linux.close(cfd);
    iters = 0;
    while (!destroyed.fired and iters < 50) : (iters += 1) {
        try d.loop.dispatch(20);
    }
    try testing.expect(destroyed.fired);
    try testing.expect(d.client_list.empty());
}

const interface = @import("interface.zig");

/// A small fake global used by the roundtrip test: a "wl_compositor" v4 with
/// one request and one event. The signatures are irrelevant here (we never
/// dispatch a request to it), but a real interface is needed so the resource is
/// interface-typed.
const fake_compositor = interface.Interface{
    .name = "wl_compositor",
    .version = 4,
    .requests = &.{
        .{ .name = "create_surface", .signature = "n", .types = &.{null} },
    },
    .events = &.{},
};

/// Records that the bind callback ran, and the resource it created.
const BindRecorder = struct {
    bound: bool = false,
    last_version: u32 = 0,
    last_id: u32 = 0,
    resource: ?*Object = null,

    fn bindFn(client: *Client, data: ?*anyopaque, version: u32, id: u32) void {
        const self: *BindRecorder = @ptrCast(@alignCast(data.?));
        self.bound = true;
        self.last_version = version;
        self.last_id = id;
        // The bind callback creates the resource (like libwayland's bind impls).
        const res = Object.create(client, &fake_compositor, version, id) catch return;
        res.setImplementation(null, self, null);
        self.resource = res;
    }
};

/// Send a raw wire message: header(object_id, opcode, size) + body bytes.
fn sendRaw(fd: i32, object_id: u32, opcode: u16, body: []const u8) !void {
    var hdr: [8]u8 = undefined;
    const size: u32 = @intCast(8 + body.len);
    std.mem.writeInt(u32, hdr[0..4], object_id, .little);
    std.mem.writeInt(u32, hdr[4..8], (size << 16) | opcode, .little);
    var buf: [256]u8 = undefined;
    @memcpy(buf[0..8], &hdr);
    @memcpy(buf[8 .. 8 + body.len], body);
    const rc = linux.write(fd, &buf, 8 + body.len);
    if (posix.errno(rc) != .SUCCESS) return error.WriteFailed;
}

/// Read one complete wire message off the raw client fd into `out`, driving the
/// server loop between attempts so the server can flush. Returns the message
/// size (header + body).
fn readEvent(d: *Display, fd: i32, out: []u8) !usize {
    var iters: u32 = 0;
    while (iters < 100) : (iters += 1) {
        d.flushClients();
        // Try to read a header.
        const rc = linux.read(fd, out.ptr, out.len);
        const e = posix.errno(rc);
        if (e == .SUCCESS) {
            const n: usize = @intCast(rc);
            if (n >= 8) return n;
        }
        try d.loop.dispatch(20);
    }
    return error.NoEvent;
}

test "server: get_registry advertises a global, bind + sync + error roundtrip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];

    const d = try Display.create(testing.allocator);
    defer d.destroy();

    // Register a test global before any client binds it.
    var recorder = BindRecorder{};
    const g = try d.globalCreate(&fake_compositor, 4, BindRecorder.bindFn, &recorder);

    var created = ClientCreatedObserver{ .listener = .{ .link = undefined, .notify = ClientCreatedObserver.onCreated } };
    created.listener.link.init();
    d.client_created_signal.add(&created.listener);

    var name_buf: [16]u8 = undefined;
    const name = try d.addSocketAutoInDir(dir, &name_buf);
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ dir, name });

    const cfd = try rawConnect(full_path);
    defer _ = linux.close(cfd);
    // Make the raw client fd nonblocking so readEvent never blocks indefinitely.
    {
        const F_GETFL: i32 = 3;
        const F_SETFL: i32 = 4;
        const O_NONBLOCK: usize = 0o4000;
        const fl = linux.fcntl(cfd, F_GETFL, 0);
        _ = linux.fcntl(cfd, F_SETFL, fl | O_NONBLOCK);
    }

    // Drive until the client is accepted.
    var iters: u32 = 0;
    while (!created.fired and iters < 50) : (iters += 1) try d.loop.dispatch(20);
    try testing.expect(created.fired);
    const client = created.last_client.?;

    // ---- get_registry(new_id=2) ----
    {
        var body: [4]u8 = undefined;
        std.mem.writeInt(u32, &body, 2, .little);
        try sendRaw(cfd, DISPLAY_ID, 1, &body);
    }
    // Drive until the registry object exists server-side.
    iters = 0;
    while (client.getObject(2) == null and iters < 50) : (iters += 1) try d.loop.dispatch(20);
    try testing.expect(client.getObject(2) != null);
    try testing.expect(client.getObject(2).?.getInterface() == &interface.wl_registry);

    // The client should receive wl_registry.global(name, "wl_compositor", 4).
    var ev: [256]u8 = undefined;
    {
        const n = try readEvent(d, cfd, &ev);
        var r = try wire.Reader.init(ev[0..n]);
        try testing.expectEqual(@as(u32, 2), r.object_id); // the registry
        try testing.expectEqual(interface.REGISTRY_GLOBAL, r.opcode);
        const adv_name = try r.readUint();
        const adv_iface = (try r.readString()).?;
        const adv_version = try r.readUint();
        try testing.expectEqual(g.name, adv_name);
        try testing.expectEqualStrings("wl_compositor", adv_iface);
        try testing.expectEqual(@as(u32, 4), adv_version);
    }

    // ---- bind(name, "wl_compositor", 4, new_id=3) ----
    {
        var w = wire.Writer.init();
        defer w.deinit(testing.allocator);
        try w.begin(testing.allocator, 2, 0); // registry id 2, opcode 0 (bind)
        try w.writeUint(testing.allocator, g.name);
        try w.writeString(testing.allocator, "wl_compositor");
        try w.writeUint(testing.allocator, 4);
        try w.writeNewId(testing.allocator, 3);
        const buf = w.finish();
        const rc = linux.write(cfd, buf.ptr, buf.len);
        if (posix.errno(rc) != .SUCCESS) return error.WriteFailed;
    }
    iters = 0;
    while (!recorder.bound and iters < 50) : (iters += 1) try d.loop.dispatch(20);
    try testing.expect(recorder.bound);
    try testing.expectEqual(@as(u32, 3), recorder.last_id);
    try testing.expectEqual(@as(u32, 4), recorder.last_version);
    try testing.expect(client.getObject(3) != null);
    try testing.expect(client.getObject(3).?.getInterface() == &fake_compositor);
    try testing.expectEqual(@as(u32, 4), client.getObject(3).?.getVersion());

    // ---- sync(new_id=4) ----
    {
        var body: [4]u8 = undefined;
        std.mem.writeInt(u32, &body, 4, .little);
        try sendRaw(cfd, DISPLAY_ID, 0, &body);
    }
    // Expect two events on the wire: wl_callback.done(serial) and
    // wl_display.delete_id(4). Order: done is posted first, then destroy emits
    // delete_id.
    {
        const n = try readEvent(d, cfd, &ev);
        // Two messages may arrive in one read; parse sequentially.
        var off: usize = 0;
        var saw_done = false;
        var saw_delete = false;
        while (off + 8 <= n) {
            var r = try wire.Reader.init(ev[off..n]);
            if (r.object_id == 4 and r.opcode == interface.CALLBACK_DONE) {
                const serial = try r.readUint();
                try testing.expect(serial > 0);
                saw_done = true;
            } else if (r.object_id == DISPLAY_ID and r.opcode == interface.DISPLAY_DELETE_ID) {
                const del = try r.readUint();
                try testing.expectEqual(@as(u32, 4), del);
                saw_delete = true;
            }
            off += r.size;
        }
        try testing.expect(saw_done);
        try testing.expect(saw_delete);
    }
    // The callback id 4 was destroyed server-side.
    try testing.expect(client.getObject(4) == null);

    // ---- error path: post wl_display.error and assert the wire bytes ----
    // Send a request to a non-existent object id; the server posts
    // wl_display.error(object=0, code=invalid_object, message).
    try sendRaw(cfd, 999, 0, &.{});
    {
        const n = try readEvent(d, cfd, &ev);
        var r = try wire.Reader.init(ev[0..n]);
        try testing.expectEqual(DISPLAY_ID, r.object_id);
        try testing.expectEqual(interface.DISPLAY_ERROR, r.opcode);
        const err_obj = try r.readObject();
        const err_code = try r.readUint();
        const err_msg = (try r.readString()).?;
        try testing.expectEqual(@as(u32, 0), err_obj);
        try testing.expectEqual(interface.DisplayErrorCode.invalid_object, err_code);
        try testing.expect(std.mem.indexOf(u8, err_msg, "invalid object") != null);
    }
}
