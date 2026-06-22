//! Wayland client connection layer.
//!
//! Connects to the compositor over the Unix domain socket at
//! $WAYLAND_DISPLAY (or $XDG_RUNTIME_DIR/wayland-0), bootstraps
//! wl_display + wl_registry, and drives an event dispatch loop.
//!
//! Requires std.Io (Zig 0.16 async IO runtime) from the caller.

const std = @import("std");
// Core wire-protocol primitives, imported by path.
const core = struct {
    pub const Fixed = @import("fixed.zig").Fixed;
    pub const Writer = @import("wire.zig").Writer;
    pub const Reader = @import("wire.zig").Reader;
    pub const WireError = @import("wire.zig").WireError;
};
const interface_mod = @import("interface.zig");
const argument_mod = @import("argument.zig");

pub const Interface = interface_mod.Interface;
pub const Argument = argument_mod.Argument;

pub const Fixed = core.Fixed;
pub const WireWriter = core.Writer;
pub const WireReader = core.Reader;
pub const WireError = core.WireError;

/// Maps Wayland object ids (u32) to opaque client-side proxy state.
/// Object id 1 is always wl_display.
pub const ObjectMap = struct {
    allocator: std.mem.Allocator,
    objects: std.AutoHashMap(u32, *anyopaque),
    next_id: u32,

    pub fn init(allocator: std.mem.Allocator) ObjectMap {
        return .{
            .allocator = allocator,
            .objects = std.AutoHashMap(u32, *anyopaque).init(allocator),
            .next_id = 2, // 1 is reserved for wl_display
        };
    }

    pub fn deinit(self: *ObjectMap) void {
        self.objects.deinit();
        self.* = undefined;
    }

    /// Allocate the next available object id.
    pub fn allocId(self: *ObjectMap) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    pub fn put(self: *ObjectMap, id: u32, ptr: *anyopaque) !void {
        try self.objects.put(id, ptr);
    }

    pub fn get(self: *ObjectMap, id: u32) ?*anyopaque {
        return self.objects.get(id);
    }

    pub fn remove(self: *ObjectMap, id: u32) void {
        _ = self.objects.remove(id);
    }
};

pub const RegistryGlobal = struct {
    name: u32,
    interface: []const u8,
    version: u32,
};

/// Decode a wl_registry.global event (opcode 0) from a WireReader.
/// Returns a RegistryGlobal whose interface slice points into reader's buffer.
pub fn decodeRegistryGlobal(r: *WireReader) !RegistryGlobal {
    const name = try r.readUint();
    const interface = (try r.readString()) orelse return error.NullInterface;
    const version = try r.readUint();
    return RegistryGlobal{ .name = name, .interface = interface, .version = version };
}

/// A connected Wayland client session.
pub const Connection = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    objects: ObjectMap,
    wire_writer: WireWriter,
    read_buf: []u8,
    write_buf: []u8,
    // Out-of-band fds received via SCM_RIGHTS (e.g. a wp_drm_lease_device_v1
    // drm_fd), queued in arrival order; takeFd() pops the oldest.
    recv_fds: [8]std.posix.fd_t = undefined,
    recv_fd_count: usize = 0,

    /// Pop the oldest received fd, or null if none are queued. The caller owns
    /// it and must close it.
    pub fn takeFd(self: *Connection) ?std.posix.fd_t {
        if (self.recv_fd_count == 0) return null;
        const fd = self.recv_fds[0];
        self.recv_fd_count -= 1;
        for (0..self.recv_fd_count) |i| self.recv_fds[i] = self.recv_fds[i + 1];
        return fd;
    }

    pub fn deinit(self: *Connection) void {
        self.stream.close(self.io);
        for (self.recv_fds[0..self.recv_fd_count]) |fd| _ = std.posix.system.close(fd);
        self.objects.deinit();
        self.wire_writer.deinit(self.allocator);
        self.allocator.free(self.read_buf);
        self.allocator.free(self.write_buf);
        self.* = undefined;
    }

    /// Send a raw wire-format message to the compositor.
    ///
    /// Writes the socket fd directly (looping over partial writes). A buffered
    /// std.Io writer is not used here: the out-of-band fd send for
    /// wl_shm.create_pool (shm.sendFd) writes the same fd via sendmsg, and a
    /// separate buffered writer could reorder bytes relative to it.
    pub fn sendMessage(self: *Connection, buf: []const u8) !void {
        const fd = self.stream.socket.handle;
        var off: usize = 0;
        while (off < buf.len) {
            // std.posix.write was removed in 0.16; use the raw syscall layer
            // (same layer shm.zig uses for sendmsg) with errno handling.
            const rc = std.posix.system.write(fd, buf.ptr + off, buf.len - off);
            switch (std.posix.errno(rc)) {
                .SUCCESS => off += @intCast(rc),
                .INTR => {},
                else => return error.WriteFailed,
            }
        }
    }

    /// Read exactly `out.len` bytes from the compositor, looping over partial
    /// reads.
    ///
    /// Reads the fd directly rather than through a buffered std.Io reader.
    /// libwayland keeps a persistent ring buffer and never discards data; a
    /// fresh buffered reader per call would over-read a batched header+body
    /// into its private buffer, return only the requested bytes, then drop the
    /// remainder - making the next read block forever. Exact-length direct
    /// reads leave any extra bytes in the kernel socket buffer for the next
    /// call, so nothing is lost.
    pub fn recvBytes(self: *Connection, out: []u8) !usize {
        const system = std.posix.system;
        const fd = self.stream.socket.handle;
        var total: usize = 0;
        while (total < out.len) {
            // recvmsg (not read) so we also pick up any SCM_RIGHTS fds the
            // compositor attaches to a message (read() silently drops them).
            var iov = std.posix.iovec{ .base = out.ptr + total, .len = out.len - total };
            var cmsg_buf: [256]u8 align(8) = undefined;
            var msg = std.posix.msghdr{
                .name = null,
                .namelen = 0,
                .iov = @ptrCast(&iov),
                .iovlen = 1,
                .control = &cmsg_buf,
                .controllen = cmsg_buf.len,
                .flags = 0,
            };
            const rc = system.recvmsg(fd, &msg, 0);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return error.ReadFailed,
            }
            const n: usize = @intCast(rc);
            if (n == 0) break; // peer closed the connection
            self.collectFds(&msg);
            total += n;
        }
        return total;
    }

    /// Pull any SCM_RIGHTS fds out of a recvmsg control buffer into the queue.
    fn collectFds(self: *Connection, msg: *const std.posix.msghdr) void {
        const Cmsghdr = std.posix.system.cmsghdr;
        const hdr_size = @sizeOf(Cmsghdr);
        if (msg.controllen < hdr_size) return;
        const cmsg: *const Cmsghdr = @ptrCast(@alignCast(msg.control.?));
        if (cmsg.level != std.posix.SOL.SOCKET or cmsg.type != std.posix.SCM.RIGHTS) return;
        const base: [*]const u8 = @ptrCast(msg.control.?);
        const nfds = (cmsg.len - hdr_size) / @sizeOf(std.posix.fd_t);
        var i: usize = 0;
        while (i < nfds) : (i += 1) {
            const p: *align(1) const std.posix.fd_t = @ptrCast(base + hdr_size + i * @sizeOf(std.posix.fd_t));
            if (self.recv_fd_count < self.recv_fds.len) {
                self.recv_fds[self.recv_fd_count] = p.*;
                self.recv_fd_count += 1;
            } else {
                _ = std.posix.system.close(p.*); // queue full: don't leak
            }
        }
    }
};

/// Error set for connect().
pub const ConnectError = std.Io.net.UnixAddress.ConnectError || error{
    NameTooLong,
    NoDisplayPath,
    OutOfMemory,
};

/// Connect to the Wayland compositor.
///
/// `socket_path` is the path to the socket file. To resolve from environment
/// variables, the caller should pass:
///   - environ_map.get("WAYLAND_DISPLAY") joined with environ_map.get("XDG_RUNTIME_DIR")
/// or simply pass a pre-resolved path.
pub fn connect(
    allocator: std.mem.Allocator,
    io: std.Io,
    socket_path: []const u8,
) ConnectError!Connection {
    const addr = std.Io.net.UnixAddress.init(socket_path) catch return error.NameTooLong;
    const stream = try addr.connect(io);
    errdefer stream.close(io);

    const read_buf = try allocator.alloc(u8, 4096);
    errdefer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, 4096);
    errdefer allocator.free(write_buf);

    return Connection{
        .allocator = allocator,
        .io = io,
        .stream = stream,
        .objects = ObjectMap.init(allocator),
        .wire_writer = WireWriter.init(),
        .read_buf = read_buf,
        .write_buf = write_buf,
    };
}

/// Resolve the Wayland display socket path from an environ map.
/// The caller owns the returned string (it may point into environ_map).
pub fn resolveSocketPath(
    environ_map: *const std.process.Environ.Map,
    buf: []u8,
) ![]const u8 {
    const display = environ_map.get("WAYLAND_DISPLAY");
    const runtime_dir = environ_map.get("XDG_RUNTIME_DIR");

    if (display) |d| {
        if (d.len > 0 and d[0] == '/') return d;
        if (runtime_dir) |rd| {
            return std.fmt.bufPrint(buf, "{s}/{s}", .{ rd, d }) catch return error.NameTooLong;
        }
    }
    if (runtime_dir) |rd| {
        return std.fmt.bufPrint(buf, "{s}/wayland-0", .{rd}) catch return error.NameTooLong;
    }
    return error.NoDisplayPath;
}

/// Send the wl_display.get_registry request (opcode 1).
/// Returns the id allocated for the new wl_registry object.
pub fn getRegistry(conn: *Connection) !u32 {
    const registry_id = conn.objects.allocId();
    try conn.wire_writer.begin(conn.allocator, 1, 1);
    try conn.wire_writer.writeNewId(conn.allocator, registry_id);
    const buf = conn.wire_writer.finish();
    try conn.sendMessage(buf);
    return registry_id;
}

/// Send the wl_display.sync request (opcode 0).
/// Returns the id allocated for the wl_callback object.
pub fn sync(conn: *Connection) !u32 {
    const cb_id = conn.objects.allocId();
    try conn.wire_writer.begin(conn.allocator, 1, 0);
    try conn.wire_writer.writeNewId(conn.allocator, cb_id);
    const buf = conn.wire_writer.finish();
    try conn.sendMessage(buf);
    return cb_id;
}

/// Send wl_registry.bind (opcode 0).
/// Allocates a new object id, writes the bind message, returns the new id.
/// Wire format: name(u32), interface(string), version(u32), id(new_id)
pub fn bindGlobal(
    conn: *Connection,
    registry_id: u32,
    global_name: u32,
    interface: []const u8,
    version: u32,
) !u32 {
    const new_id = conn.objects.allocId();
    try conn.wire_writer.begin(conn.allocator, registry_id, 0);
    try conn.wire_writer.writeUint(conn.allocator, global_name);
    try conn.wire_writer.writeString(conn.allocator, interface);
    try conn.wire_writer.writeUint(conn.allocator, version);
    try conn.wire_writer.writeNewId(conn.allocator, new_id);
    const buf = conn.wire_writer.finish();
    try conn.sendMessage(buf);
    return new_id;
}

/// Read the next wire message from the compositor.
/// `buf` must be large enough to hold the complete message.
/// Returns a parsed WireReader for the message.
pub fn dispatchOne(conn: *Connection, buf: []u8) !WireReader {
    if (buf.len < 8) return error.BufferTooSmall;
    const n = try conn.recvBytes(buf[0..8]);
    if (n < 8) return error.EndOfStream;
    // Peek the header to learn the full message size; the body has not been
    // read yet, so init (which requires the whole message) cannot be used here.
    const hdr = try WireReader.parseHeader(buf[0..8]);
    const msg_size: usize = hdr.size;
    if (msg_size > buf.len) return error.BufferTooSmall;
    if (msg_size > 8) {
        const rest = try conn.recvBytes(buf[8..msg_size]);
        if (rest < msg_size - 8) return error.EndOfStream;
    }
    return WireReader.init(buf[0..msg_size]);
}

/// Routes an incoming event (object_id, opcode) to the right interface so the
/// argument codec can decode it.
///
/// libwayland keeps the bound interface on each client-side proxy (wl_proxy);
/// when a message arrives, it looks the proxy up by id, reads its interface's
/// events[opcode] signature, and demarshals against that. This is the abstract
/// equivalent: the consumer (a generated-bindings client) records the interface
/// it bound for each object id, and the dispatch loop reads events[opcode] off
/// it to demarshal. No protocol is baked in - the Interface tables come from
/// the generated bindings the consumer chose.
pub const InterfaceMap = struct {
    map: std.AutoHashMap(u32, *const Interface),

    pub fn init(allocator: std.mem.Allocator) InterfaceMap {
        return .{ .map = std.AutoHashMap(u32, *const Interface).init(allocator) };
    }

    pub fn deinit(self: *InterfaceMap) void {
        self.map.deinit();
        self.* = undefined;
    }

    /// Record that object `id` is of interface `iface`.
    pub fn set(self: *InterfaceMap, id: u32, iface: *const Interface) !void {
        try self.map.put(id, iface);
    }

    pub fn get(self: *InterfaceMap, id: u32) ?*const Interface {
        return self.map.get(id);
    }

    pub fn remove(self: *InterfaceMap, id: u32) void {
        _ = self.map.remove(id);
    }
};

/// One decoded incoming event: which object, which opcode, and the demarshalled
/// arguments (aliasing the reader's buffer; valid until the next dispatchOne).
pub const DecodedEvent = struct {
    object_id: u32,
    opcode: u16,
    interface: *const Interface,
    args: []const Argument,
};

/// Read the next event off the wire and demarshal it against the bound
/// interface of its target object.
///
/// `buf` holds the raw wire message; `args_out` receives the decoded args
/// (must be at least as long as the event's arg count). Strings/arrays in the
/// result alias `buf`, so the caller must use them before the next call.
///
/// Returns null when the object id is unknown (an event for an object we never
/// recorded an interface for); the message is still consumed.
pub fn dispatchEvent(
    conn: *Connection,
    imap: *InterfaceMap,
    buf: []u8,
    args_out: []Argument,
) !?DecodedEvent {
    var r = try dispatchOne(conn, buf);
    const iface = imap.get(r.object_id) orelse return null;
    if (r.opcode >= iface.events.len) return error.UnknownOpcode;
    const msg = iface.events[r.opcode];
    const n = interface_mod.argCount(msg.signature);
    if (n > args_out.len) return error.BufferTooSmall;
    // No event we decode here carries an fd ('h'); pass null for the server
    // connection that demarshal would otherwise pull fds from.
    try argument_mod.demarshal(&r, null, msg.signature, args_out[0..n]);
    return DecodedEvent{
        .object_id = r.object_id,
        .opcode = r.opcode,
        .interface = iface,
        .args = args_out[0..n],
    };
}

test "InterfaceMap records and looks up an interface by id" {
    const wl_registry: Interface = .{
        .name = "wl_registry",
        .version = 1,
        .requests = &.{},
        .events = &.{
            .{ .name = "global", .signature = "usu", .types = &.{} },
            .{ .name = "global_remove", .signature = "u", .types = &.{} },
        },
    };
    var imap = InterfaceMap.init(std.testing.allocator);
    defer imap.deinit();
    try imap.set(2, &wl_registry);
    try std.testing.expect(imap.get(2) != null);
    try std.testing.expectEqualStrings("wl_registry", imap.get(2).?.name);
    try std.testing.expect(imap.get(99) == null);
    imap.remove(2);
    try std.testing.expect(imap.get(2) == null);
}

test "demarshal a registry.global event against its interface signature" {
    // Mirrors what dispatchEvent does once the wire message is read: find the
    // event's signature on the bound interface, then demarshal against it.
    const allocator = std.testing.allocator;
    const wl_registry: Interface = .{
        .name = "wl_registry",
        .version = 1,
        .requests = &.{},
        .events = &.{
            .{ .name = "global", .signature = "usu", .types = &.{} },
            .{ .name = "global_remove", .signature = "u", .types = &.{} },
        },
    };

    var w = WireWriter.init();
    defer w.deinit(allocator);
    try w.begin(allocator, 2, 0); // registry id=2, opcode 0 (global)
    try w.writeUint(allocator, 7); // name
    try w.writeString(allocator, "wl_output"); // interface
    try w.writeUint(allocator, 4); // version
    const buf = w.finish();

    var r = try WireReader.init(buf);
    const msg = wl_registry.events[r.opcode];
    const n = interface_mod.argCount(msg.signature);
    var args: [8]Argument = undefined;
    try argument_mod.demarshal(&r, null, msg.signature, args[0..n]);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(u32, 7), args[0].uint);
    try std.testing.expectEqualStrings("wl_output", args[1].string.?);
    try std.testing.expectEqual(@as(u32, 4), args[2].uint);
}

test "ObjectMap alloc and lookup" {
    var map = ObjectMap.init(std.testing.allocator);
    defer map.deinit();

    const id = map.allocId();
    try std.testing.expectEqual(@as(u32, 2), id);
    const id2 = map.allocId();
    try std.testing.expectEqual(@as(u32, 3), id2);
}

test "ObjectMap remove" {
    var map = ObjectMap.init(std.testing.allocator);
    defer map.deinit();

    var dummy: u8 = 0;
    try map.put(10, @ptrCast(&dummy));
    try std.testing.expect(map.get(10) != null);
    map.remove(10);
    try std.testing.expect(map.get(10) == null);
}

test "decode registry.global event" {
    const allocator = std.testing.allocator;
    var w = WireWriter.init();
    defer w.deinit(allocator);

    // object_id=2 (registry), opcode=0 (global)
    try w.begin(allocator, 2, 0);
    try w.writeUint(allocator, 1); // name
    try w.writeString(allocator, "wl_compositor"); // interface
    try w.writeUint(allocator, 4); // version
    const buf = w.finish();

    var r = try WireReader.init(buf);
    const g = try decodeRegistryGlobal(&r);
    try std.testing.expectEqual(@as(u32, 1), g.name);
    try std.testing.expectEqualStrings("wl_compositor", g.interface);
    try std.testing.expectEqual(@as(u32, 4), g.version);
}

test "build registry.bind wire message" {
    const allocator = std.testing.allocator;
    var w = WireWriter.init();
    defer w.deinit(allocator);

    // wl_registry.bind opcode=0: name(u32), interface(string), version(u32), id(new_id)
    const new_id: u32 = 3;
    try w.begin(allocator, 2, 0);
    try w.writeUint(allocator, 1);
    try w.writeString(allocator, "wl_compositor");
    try w.writeUint(allocator, 4);
    try w.writeNewId(allocator, new_id);
    const buf = w.finish();

    var r = try WireReader.init(buf);
    try std.testing.expectEqual(@as(u32, 2), r.object_id);
    try std.testing.expectEqual(@as(u16, 0), r.opcode);
    const bname = try r.readUint();
    try std.testing.expectEqual(@as(u32, 1), bname);
    const biface = (try r.readString()).?;
    try std.testing.expectEqualStrings("wl_compositor", biface);
    const bver = try r.readUint();
    try std.testing.expectEqual(@as(u32, 4), bver);
    const bid = try r.readNewId();
    try std.testing.expectEqual(@as(u32, 3), bid);
}

test "build wl_shm.create_pool wire message" {
    const allocator = std.testing.allocator;
    var w = WireWriter.init();
    defer w.deinit(allocator);

    // wl_shm.create_pool opcode=0: new_id(pool), fd(placeholder u32=0), size(i32)
    try w.begin(allocator, 3, 0);
    try w.writeNewId(allocator, 4);
    try w.writeUint(allocator, 0); // fd placeholder (sent OOB)
    try w.writeInt(allocator, 4096);
    const buf = w.finish();

    var r = try WireReader.init(buf);
    try std.testing.expectEqual(@as(u32, 3), r.object_id);
    try std.testing.expectEqual(@as(u16, 0), r.opcode);
    const pool_id = try r.readNewId();
    try std.testing.expectEqual(@as(u32, 4), pool_id);
    _ = try r.readUint(); // fd placeholder
    const sz = try r.readInt();
    try std.testing.expectEqual(@as(i32, 4096), sz);
}

test "build wl_shm_pool.create_buffer wire message" {
    const allocator = std.testing.allocator;
    var w = WireWriter.init();
    defer w.deinit(allocator);

    // wl_shm_pool.create_buffer opcode=0: new_id, offset, width, height, stride, format
    try w.begin(allocator, 4, 0);
    try w.writeNewId(allocator, 5);
    try w.writeInt(allocator, 0); // offset
    try w.writeInt(allocator, 320); // width
    try w.writeInt(allocator, 240); // height
    try w.writeInt(allocator, 320 * 4); // stride
    try w.writeUint(allocator, 0); // format=XR24
    const buf = w.finish();

    var r = try WireReader.init(buf);
    try std.testing.expectEqual(@as(u32, 4), r.object_id);
    const bid = try r.readNewId();
    try std.testing.expectEqual(@as(u32, 5), bid);
    try std.testing.expectEqual(@as(i32, 0), try r.readInt());
    try std.testing.expectEqual(@as(i32, 320), try r.readInt());
    try std.testing.expectEqual(@as(i32, 240), try r.readInt());
    try std.testing.expectEqual(@as(i32, 320 * 4), try r.readInt());
    try std.testing.expectEqual(@as(u32, 0), try r.readUint());
}

test "cmsghdr SCM_RIGHTS layout for one fd" {
    // A cmsghdr for one i32 fd on Linux:
    // len = @sizeOf(cmsghdr) + @sizeOf(i32)
    // level = SOL.SOCKET = 1
    // type = SCM.RIGHTS = 1
    const Cmsghdr = std.posix.system.cmsghdr;
    const hdr_size = @sizeOf(Cmsghdr);
    const fd_size = @sizeOf(i32);
    const expected_len = hdr_size + fd_size;

    var cmsg_buf: [64]u8 align(8) = std.mem.zeroes([64]u8);
    const cmsg: *Cmsghdr = @ptrCast(@alignCast(&cmsg_buf));
    cmsg.len = expected_len;
    cmsg.level = std.posix.SOL.SOCKET;
    cmsg.type = std.posix.SCM.RIGHTS;

    // Write fd value after the header
    const fd_ptr: *i32 = @ptrCast(@alignCast(cmsg_buf[hdr_size..].ptr));
    fd_ptr.* = 42;

    try std.testing.expectEqual(expected_len, cmsg.len);
    try std.testing.expectEqual(std.posix.SOL.SOCKET, cmsg.level);
    try std.testing.expectEqual(std.posix.SCM.RIGHTS, cmsg.type);
    try std.testing.expectEqual(@as(i32, 42), fd_ptr.*);
}

test "build wl_compositor.create_surface wire message" {
    const allocator = std.testing.allocator;
    var w = WireWriter.init();
    defer w.deinit(allocator);

    // wl_compositor.create_surface opcode=0: new_id
    try w.begin(allocator, 3, 0); // compositor_id=3
    try w.writeNewId(allocator, 4); // surface_id=4
    const buf = w.finish();

    var r = try WireReader.init(buf);
    try std.testing.expectEqual(@as(u32, 3), r.object_id);
    try std.testing.expectEqual(@as(u16, 0), r.opcode);
    try std.testing.expectEqual(@as(u32, 4), try r.readNewId());
}

test "build xdg_wm_base.get_xdg_surface wire message" {
    const allocator = std.testing.allocator;
    var w = WireWriter.init();
    defer w.deinit(allocator);

    // xdg_wm_base.get_xdg_surface opcode=2: new_id, surface_object
    try w.begin(allocator, 5, 2); // xdg_wm_base_id=5
    try w.writeNewId(allocator, 6); // xdg_surface_id=6
    try w.writeObject(allocator, 4); // surface_id=4
    const buf = w.finish();

    var r = try WireReader.init(buf);
    try std.testing.expectEqual(@as(u32, 5), r.object_id);
    try std.testing.expectEqual(@as(u16, 2), r.opcode);
    try std.testing.expectEqual(@as(u32, 6), try r.readNewId());
    try std.testing.expectEqual(@as(u32, 4), try r.readObject());
}

test "build xdg_surface.ack_configure wire message" {
    const allocator = std.testing.allocator;
    var w = WireWriter.init();
    defer w.deinit(allocator);

    // xdg_surface.ack_configure opcode=4: serial(u32)
    try w.begin(allocator, 6, 4); // xdg_surface_id=6
    try w.writeUint(allocator, 42); // serial
    const buf = w.finish();

    var r = try WireReader.init(buf);
    try std.testing.expectEqual(@as(u32, 6), r.object_id);
    try std.testing.expectEqual(@as(u16, 4), r.opcode);
    try std.testing.expectEqual(@as(u32, 42), try r.readUint());
}

test "build wl_surface.attach wire message" {
    const allocator = std.testing.allocator;
    var w = WireWriter.init();
    defer w.deinit(allocator);

    // wl_surface.attach opcode=1: buffer_id, x, y
    try w.begin(allocator, 4, 1); // surface_id=4
    try w.writeObject(allocator, 7); // buffer_id=7
    try w.writeInt(allocator, 0); // x
    try w.writeInt(allocator, 0); // y
    const buf = w.finish();

    var r = try WireReader.init(buf);
    try std.testing.expectEqual(@as(u32, 4), r.object_id);
    try std.testing.expectEqual(@as(u16, 1), r.opcode);
    try std.testing.expectEqual(@as(u32, 7), try r.readObject());
    try std.testing.expectEqual(@as(i32, 0), try r.readInt());
    try std.testing.expectEqual(@as(i32, 0), try r.readInt());
}

test "build wl_surface.damage and commit wire messages" {
    const allocator = std.testing.allocator;
    var w = WireWriter.init();
    defer w.deinit(allocator);

    // wl_surface.damage opcode=2: x, y, width, height
    try w.begin(allocator, 4, 2);
    try w.writeInt(allocator, 0);
    try w.writeInt(allocator, 0);
    try w.writeInt(allocator, 320);
    try w.writeInt(allocator, 240);
    const dam_buf = w.finish();
    try std.testing.expect(dam_buf.len > 0);

    // wl_surface.commit opcode=6: no args
    try w.begin(allocator, 4, 6);
    const com_buf = w.finish();
    try std.testing.expectEqual(@as(usize, 8), com_buf.len); // header only
}
