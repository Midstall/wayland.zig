//! wl_client equivalent (server side) + the per-client object map and the
//! minimal server-side Object/Resource.
//!
//! Mirrors libwayland's `struct wl_client` (src/wayland-server.c). A Client
//! owns one buffered wire Connection over the accepted socket fd, a map from
//! object id to *Object, and is itself an event-loop fd source. On readable it
//! drains complete messages and routes each to the target object's dispatcher
//! hook. On hangup / peer close / fatal error it is destroyed.
//!
//! The object id space follows libwayland: client-allocated ids occupy
//! 1 .. 0xfeffffff, server-allocated ids occupy 0xff000000 .. 0xffffffff. The
//! wl_display object (id 1) is implicitly present in every client's map at
//! connect, like libwayland (it is the client's first resource).
//!
//! Covers framing + routing + the object map + credentials + clean teardown,
//! plus the full wl_resource (post_event marshalling,
//! set_implementation/dispatcher, getters) and the real wl_display requests
//! (get_registry, sync).

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const Link = @import("list.zig").Link;
const Signal = @import("signal.zig").Signal;
const event_loop = @import("event_loop.zig");
const EventSource = event_loop.EventSource;
const Connection = @import("connection.zig").Connection;
const wire = @import("wire.zig");
const Display = @import("display.zig").Display;
const interface = @import("interface.zig");
const Interface = interface.Interface;
const argument = @import("argument.zig");
const Argument = argument.Argument;
const global_mod = @import("global.zig");
const Global = global_mod.Global;

/// Server-allocated ids start here (libwayland WL_SERVER_ID_START).
pub const SERVER_ID_START: u32 = 0xff000000;
/// The wl_display object is always id 1 in every client.
pub const DISPLAY_ID: u32 = 1;

pub const ClientError = error{
    OutOfMemory,
    ConnectionError,
};

/// A dispatcher hook: invoked when a request targeting `object` arrives. Given
/// the receiving object, the opcode, and a Reader positioned just past the
/// 8-byte header (so the hook reads the args). Returns 0 on success or a
/// negative value to signal a protocol error.
/// Mirrors the shape of libwayland's wl_dispatcher_func_t, simplified.
pub const DispatchFn = *const fn (object: *Object, opcode: u16, reader: *wire.Reader) c_int;

/// A resource destroy hook (wl_resource_destroy_func_t), invoked when the
/// object is destroyed, before the storage is freed. Receives the object.
pub const ResourceDestroyFn = *const fn (object: *Object) void;

/// The server-side object: the full wl_resource. Carries an interface-typed
/// description (`iface`), a dispatcher, an implementation pointer + user_data,
/// and a destroy hook. `interface_name` mirrors `iface.name` when an interface
/// is set.
pub const Object = struct {
    id: u32,
    interface_name: []const u8,
    version: u32,
    client: *Client,
    link: Link,
    destroy_signal: Signal,
    /// Per-object request dispatcher (null = drop/ignore requests).
    dispatcher: ?DispatchFn = null,
    /// Implementation function table / vtable for the generated dispatcher.
    implementation: ?*const anyopaque = null,
    /// User data attached to this object (wl_resource user_data).
    user_data: ?*anyopaque = null,
    /// The typed interface (wl_resource's wl_interface). Resources created via
    /// `create` always have it.
    iface: ?*const Interface = null,
    /// Destroy hook run on destroy() before the storage is freed.
    destroy_fn: ?ResourceDestroyFn = null,
    /// Link into the owning client's resource bookkeeping (registries list, for
    /// registry objects). Unused for other objects.
    registry_link: Link = undefined,

    pub fn init(self: *Object, client: *Client, id: u32, interface_name: []const u8, version: u32) void {
        self.* = .{
            .id = id,
            .interface_name = interface_name,
            .version = version,
            .client = client,
            .link = undefined,
            .destroy_signal = undefined,
        };
        self.link.init();
        self.registry_link.init();
        self.destroy_signal.init();
    }

    /// Initialize an interface-typed resource. Mirrors the field-setup half of
    /// wl_resource_create. interface_name aliases iface.name.
    pub fn initTyped(self: *Object, client: *Client, iface: *const Interface, version: u32, id: u32) void {
        self.init(client, id, iface.name, version);
        self.iface = iface;
    }

    /// Allocate + register an interface-typed resource at `id` on `client`.
    /// Mirrors wl_resource_create.
    pub fn create(client: *Client, iface: *const Interface, version: u32, id: u32) ClientError!*Object {
        const obj = client.allocator.create(Object) catch return error.OutOfMemory;
        errdefer client.allocator.destroy(obj);
        obj.initTyped(client, iface, version, id);
        try client.registerObject(obj);
        return obj;
    }

    /// Attach an implementation vtable, user data, and an optional destroy hook.
    /// Mirrors wl_resource_set_implementation.
    pub fn setImplementation(
        self: *Object,
        impl: ?*const anyopaque,
        user_data: ?*anyopaque,
        destroy_fn: ?ResourceDestroyFn,
    ) void {
        self.implementation = impl;
        self.user_data = user_data;
        self.destroy_fn = destroy_fn;
    }

    /// Set the request dispatcher. Mirrors wl_resource_set_dispatcher (the
    /// generated server bindings install one).
    pub fn setDispatcher(self: *Object, d: DispatchFn) void {
        self.dispatcher = d;
    }

    pub fn getId(self: *const Object) u32 {
        return self.id;
    }
    pub fn getClient(self: *Object) *Client {
        return self.client;
    }
    pub fn getVersion(self: *const Object) u32 {
        return self.version;
    }
    pub fn getUserData(self: *const Object) ?*anyopaque {
        return self.user_data;
    }
    pub fn getInterface(self: *const Object) ?*const Interface {
        return self.iface;
    }

    /// Marshal an event (by opcode) to this resource's client, looking up the
    /// signature from the interface's events table. Mirrors
    /// wl_resource_post_event_array. Queues for the next flush.
    pub fn postEvent(self: *Object, opcode: u16, args: []const Argument) argument.ArgError!void {
        const iface = self.iface orelse return error.SignatureArgMismatch;
        const msg = iface.event(opcode) orelse return error.SignatureArgMismatch;
        try argument.marshal(
            &self.client.conn,
            self.client.allocator,
            self.id,
            opcode,
            msg.signature,
            args,
        );
    }

    /// Post wl_display.error(object=self.id, code, message) to this resource's
    /// client, then mark the client fatally errored. Mirrors
    /// wl_resource_post_error. The message is formatted into a small scratch
    /// buffer.
    pub fn postError(self: *Object, code: u32, comptime fmt: []const u8, args: anytype) void {
        self.client.postError(self.id, code, fmt, args);
    }

    /// Destroy this resource: emit the destroy signal, run the destroy hook,
    /// send wl_display.delete_id to the client (so it can recycle the id), and
    /// remove it from the client's object map (freeing the storage). Mirrors
    /// wl_resource_destroy.
    pub fn destroy(self: *Object) void {
        const client = self.client;
        const id = self.id;
        self.destroy_signal.emit(self);
        if (self.destroy_fn) |f| f(self);
        // Tell the client the id is free (libwayland sends delete_id for every
        // destroyed resource so the client's id allocator can reuse it).
        client.sendDeleteId(id);
        // Detach any registry bookkeeping before removal.
        client.removeObject(id);
    }
};

/// Process credentials of the peer (SO_PEERCRED). Mirrors what
/// wl_client_get_credentials returns.
pub const Credentials = struct {
    pid: i32,
    uid: u32,
    gid: u32,
};

/// Linux `struct ucred` (not exposed by std). Layout: pid_t, uid_t, gid_t.
const ucred = extern struct {
    pid: i32,
    uid: u32,
    gid: u32,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    display: *Display,
    conn: Connection,
    source: *EventSource,
    link: Link,

    /// id -> *Object. Owned by the client; objects freed on removal/destroy.
    objects: std.AutoHashMapUnmanaged(u32, *Object),
    /// Next server-allocated id (counts up from SERVER_ID_START).
    next_server_id: u32,

    /// The client's bound wl_registry objects (via registry_link). New globals
    /// post wl_registry.global to each; destroyed globals post global_remove.
    registry_list: Link,

    /// Set once a fatal protocol error has been posted; the client is torn down
    /// after the current dispatch returns.
    error_posted: bool,

    destroy_signal: Signal,

    /// The implicit wl_display object (id 1), embedded so it needs no separate
    /// allocation and is always present.
    display_object: Object,

    /// A scratch buffer for copying a full message out of the connection before
    /// routing. Sized to the wire maximum (header size field is u16).
    msg_buf: [65536]u8,

    /// Create a server-side client wrapping an accepted, connected socket fd.
    /// The fd is set nonblocking and registered as a READABLE|HANGUP event-loop
    /// source. The wl_display (id 1) is pre-registered. Mirrors
    /// wl_client_create. Fires the display's client_created signal.
    pub fn create(display: *Display, fd: i32) ClientError!*Client {
        const allocator = display.allocator;
        const self = allocator.create(Client) catch return error.OutOfMemory;
        errdefer allocator.destroy(self);

        setNonblock(fd);

        self.* = .{
            .allocator = allocator,
            .display = display,
            .conn = Connection.init(fd),
            .source = undefined,
            .link = undefined,
            .objects = .{},
            .next_server_id = SERVER_ID_START,
            .registry_list = undefined,
            .error_posted = false,
            .destroy_signal = undefined,
            .display_object = undefined,
            .msg_buf = undefined,
        };
        self.link.init();
        self.registry_list.init();
        self.destroy_signal.init();

        // Register the implicit wl_display object (id 1).
        self.display_object.initTyped(self, &interface.wl_display, 1, DISPLAY_ID);
        self.display_object.dispatcher = displayDispatch;
        self.objects.put(allocator, DISPLAY_ID, &self.display_object) catch {
            allocator.destroy(self);
            return error.OutOfMemory;
        };

        self.source = display.loop.addFd(
            fd,
            event_loop.READABLE | event_loop.HANGUP,
            clientReadable,
            self,
        ) catch {
            self.objects.deinit(allocator);
            allocator.destroy(self);
            return error.ConnectionError;
        };

        display.client_list.append(&self.link);
        display.client_created_signal.emit(self);
        return self;
    }

    /// Destroy the client: fire destroy signal, free all objects, remove the
    /// event source, close the connection, unlink from the display, free.
    /// Mirrors wl_client_destroy.
    pub fn destroy(self: *Client) void {
        self.destroy_signal.emit(self);

        // Fire each object's destroy signal, run its destroy hook, and free
        // heap-allocated objects.
        var it = self.objects.iterator();
        while (it.next()) |entry| {
            const obj = entry.value_ptr.*;
            obj.destroy_signal.emit(obj);
            if (obj.destroy_fn) |f| f(obj);
            if (obj != &self.display_object) {
                self.allocator.destroy(obj);
            }
        }
        self.objects.deinit(self.allocator);

        self.display.loop.eventSourceRemove(self.source);
        self.conn.close();
        self.link.remove();
        self.allocator.destroy(self);
    }

    /// Peer credentials via SO_PEERCRED. Mirrors wl_client_get_credentials.
    pub fn credentials(self: *const Client) Credentials {
        var cred: ucred = std.mem.zeroes(ucred);
        var len: linux.socklen_t = @sizeOf(ucred);
        _ = linux.getsockopt(
            self.conn.fd,
            linux.SOL.SOCKET,
            linux.SO.PEERCRED,
            @ptrCast(&cred),
            &len,
        );
        return .{ .pid = cred.pid, .uid = cred.uid, .gid = cred.gid };
    }

    /// Look up an object by id, or null. Mirrors wl_client_get_object.
    pub fn getObject(self: *Client, id: u32) ?*Object {
        return self.objects.get(id);
    }

    /// Register an already-constructed object under its id. The client takes
    /// ownership of freeing it on destroy (unless it is the embedded display).
    pub fn registerObject(self: *Client, object: *Object) ClientError!void {
        self.objects.put(self.allocator, object.id, object) catch return error.OutOfMemory;
    }

    /// Allocate + register a new object at `id` (a client-supplied new_id from a
    /// request, or a server id). Mirrors the resource-creation half of
    /// wl_resource_create.
    pub fn newObject(self: *Client, id: u32, interface_name: []const u8, version: u32) ClientError!*Object {
        const obj = self.allocator.create(Object) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(obj);
        obj.init(self, id, interface_name, version);
        try self.registerObject(obj);
        return obj;
    }

    /// Allocate a server-side id (the 0xff000000.. range). Mirrors the server
    /// side of wl_map id allocation.
    pub fn allocServerId(self: *Client) u32 {
        const id = self.next_server_id;
        self.next_server_id +%= 1;
        return id;
    }

    /// Remove (and free, if heap) an object from the map. Mirrors
    /// wl_client_remove_object half of resource destruction.
    pub fn removeObject(self: *Client, id: u32) void {
        if (self.objects.fetchRemove(id)) |kv| {
            const obj = kv.value;
            // If it was a bound registry, drop it from the advertise list.
            if (obj.iface == &interface.wl_registry) obj.registry_link.remove();
            if (obj != &self.display_object) self.allocator.destroy(obj);
        }
    }

    /// Send wl_display.delete_id(id) so the client can recycle the id. Mirrors
    /// wl_resource_destroy's destroy notification. Server-allocated ids are not
    /// recycled by clients, but libwayland still emits delete_id only for
    /// client-allocated ids; match that.
    pub fn sendDeleteId(self: *Client, id: u32) void {
        if (id >= SERVER_ID_START) return;
        const args = [_]Argument{.{ .uint = id }};
        self.display_object.postEvent(interface.DISPLAY_DELETE_ID, &args) catch {};
    }

    /// Post wl_display.error(object_id, code, message) to this client and mark
    /// it fatally errored. Mirrors wl_client_post_error. The message is
    /// formatted into a fixed scratch buffer (truncated if oversized).
    pub fn postError(self: *Client, object_id: u32, code: u32, comptime fmt: []const u8, args: anytype) void {
        if (self.error_posted) return;
        self.error_posted = true;
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..buf.len];
        const ev = [_]Argument{
            .{ .object = object_id },
            .{ .uint = code },
            .{ .string = msg },
        };
        self.display_object.postEvent(interface.DISPLAY_ERROR, &ev) catch {};
    }

    /// Flush the connection. Mirrors wl_client_flush.
    pub fn flush(self: *Client) !void {
        self.conn.flush() catch |e| {
            if (e == error.BrokenPipe) return; // peer gone; HANGUP will destroy us
            return e;
        };
    }

    /// Drain every complete message currently buffered, routing each to its
    /// target object's dispatcher. Returns the number of messages dispatched.
    /// Stops draining once a fatal protocol error has been posted (the caller
    /// tears the client down afterward).
    pub fn drainMessages(self: *Client) usize {
        var count: usize = 0;
        while (!self.error_posted) {
            const size = (self.conn.peekMessage(&self.msg_buf) catch break) orelse break;
            self.dispatchMessage(self.msg_buf[0..size]);
            self.conn.consume(size);
            count += 1;
        }
        return count;
    }

    /// Route one complete wire message to its target object's dispatcher. An
    /// unknown target object is a protocol error (invalid_object).
    fn dispatchMessage(self: *Client, msg: []const u8) void {
        var reader = wire.Reader.init(msg) catch return;
        const target = self.getObject(reader.object_id) orelse {
            self.postError(
                0,
                interface.DisplayErrorCode.invalid_object,
                "invalid object {d}",
                .{reader.object_id},
            );
            return;
        };
        if (target.dispatcher) |d| {
            _ = d(target, reader.opcode, &reader);
        }
    }

    /// Event-loop callback: socket readable / hung up. Pull bytes, drain
    /// messages, flush replies. Destroy on EOF / hangup / fatal error.
    fn clientReadable(fd: i32, mask: u32, data: ?*anyopaque) callconv(.c) c_int {
        _ = fd;
        const self: *Client = @ptrCast(@alignCast(data.?));

        if (mask & (event_loop.HANGUP | event_loop.ERROR) != 0) {
            // Drain whatever is left, then destroy.
            _ = self.conn.read() catch {};
            _ = self.drainMessages();
            self.destroy();
            return 1;
        }

        const n = self.conn.read() catch {
            self.destroy();
            return 1;
        };
        if (n == 0) {
            // Orderly peer close. But with level-triggered READABLE a closed
            // socket reports readable forever, so we must destroy on EOF. Only
            // treat n==0 as EOF when there is genuinely nothing buffered to
            // frame (EAGAIN also returns 0 but leaves the socket alive; in that
            // case there is also nothing new, so draining is a no-op and we
            // would spuriously destroy). Distinguish via a peek: if no bytes
            // are pending and the read returned 0, the peer closed.
            if (self.conn.pendingIn() == 0) {
                self.destroy();
                return 1;
            }
        }
        _ = self.drainMessages();
        self.flush() catch {};
        // A fatal protocol error was posted: flush the wl_display.error event,
        // then tear the client down (mirrors libwayland's post-error teardown).
        if (self.error_posted) {
            self.destroy();
            return 1;
        }
        return 1;
    }
};

/// wl_display requests: sync (opcode 0, new_id callback), get_registry
/// (opcode 1, new_id registry). Both are real: sync replies with
/// wl_callback.done(serial) then destroys the callback; get_registry creates a
/// registry resource, advertises every global to it, and remembers it so future
/// globals advertise too.
fn displayDispatch(object: *Object, opcode: u16, reader: *wire.Reader) c_int {
    const client = object.client;
    switch (opcode) {
        // sync(new_id callback): make a callback, fire done(serial), destroy it.
        0 => {
            const new_id = reader.readNewId() catch return -1;
            const cb = Object.create(client, &interface.wl_callback, 1, new_id) catch return -1;
            const serial = client.display.nextSerial();
            cb.postEvent(interface.CALLBACK_DONE, &.{.{ .uint = serial }}) catch {};
            cb.destroy();
            return 0;
        },
        // get_registry(new_id registry).
        1 => {
            const new_id = reader.readNewId() catch return -1;
            const reg = Object.create(client, &interface.wl_registry, 1, new_id) catch return -1;
            reg.setDispatcher(registryDispatch);
            // Remember it so new globals advertise to it.
            client.registry_list.append(&reg.registry_link);
            // Advertise every existing global to the new registry.
            var it = client.display.global_list.iterator(Global, "link");
            while (it.next()) |g| {
                reg.postEvent(interface.REGISTRY_GLOBAL, &.{
                    .{ .uint = g.name },
                    .{ .string = g.interface.name },
                    .{ .uint = g.version },
                }) catch {};
            }
            return 0;
        },
        else => return 0,
    }
}

/// wl_registry requests: bind (opcode 0). Decode (name:u, interface:s,
/// version:u, new_id:n), find the global by name, create the resource at the
/// new_id (version capped to the global's version), and invoke the global's
/// bind callback to wire it up.
fn registryDispatch(object: *Object, opcode: u16, reader: *wire.Reader) c_int {
    const client = object.client;
    if (opcode != 0) return 0;

    var args: [4]Argument = undefined;
    argument.demarshal(reader, &client.conn, "usun", &args) catch return -1;
    const name = args[0].uint;
    const requested_version = args[2].uint;
    const new_id = args[3].new_id;

    // Find the global with this registry name.
    var found: ?*Global = null;
    var it = client.display.global_list.iterator(Global, "link");
    while (it.next()) |g| {
        if (g.name == name) {
            found = g;
            break;
        }
    }
    const g = found orelse {
        client.postError(
            object.id,
            interface.DisplayErrorCode.invalid_object,
            "invalid global {d}",
            .{name},
        );
        return -1;
    };

    // Cap the version to what the global advertises. The bind callback creates
    // the resource at new_id (via Object.create + setImplementation), like
    // libwayland's registry_bind, which does not create it itself.
    const version = @min(requested_version, g.version);
    g.bind(client, g.data, version, new_id);
    return 0;
}

fn setNonblock(fd: i32) void {
    const F_GETFL: i32 = 3;
    const F_SETFL: i32 = 4;
    const O_NONBLOCK: usize = 0o4000;
    const flags = linux.fcntl(fd, F_GETFL, 0);
    _ = linux.fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

const testing = std.testing;

test "Client object map: id ranges and lookups" {
    const Display2 = @import("display.zig").Display;
    const d = try Display2.create(testing.allocator);
    defer d.destroy();

    // Fabricate a client without a real socket using a socketpair end.
    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds);
    try testing.expect(posix.errno(rc) == .SUCCESS);
    // The other end stays open for the duration so the client is not torn down.
    defer _ = linux.close(fds[1]);

    const client = try Client.create(d, fds[0]);

    // wl_display (id 1) is implicitly present.
    try testing.expect(client.getObject(DISPLAY_ID) != null);
    try testing.expectEqualStrings("wl_display", client.getObject(DISPLAY_ID).?.interface_name);

    // Client-range object.
    _ = try client.newObject(2, "wl_registry", 1);
    try testing.expect(client.getObject(2) != null);

    // Server-range id allocation.
    const sid = client.allocServerId();
    try testing.expect(sid >= SERVER_ID_START);
    const sid2 = client.allocServerId();
    try testing.expectEqual(sid + 1, sid2);

    client.removeObject(2);
    try testing.expect(client.getObject(2) == null);

    // Credentials report this process's uid.
    const cred = client.credentials();
    try testing.expectEqual(linux.getuid(), cred.uid);

    // The client is in the display's list.
    try testing.expect(!d.client_list.empty());
}
