//! wl_display equivalent (server side).
//!
//! Mirrors libwayland's `struct wl_display` (src/wayland-server.c). It owns an
//! event loop, the list of connected clients, the list of globals, a
//! monotonically increasing serial counter, and the listening
//! AF_UNIX socket(s). Each listening socket is added to the event loop as a
//! READABLE fd source whose callback accepts a connection and creates a Client.
//!
//! Raw Linux syscalls via std.os.linux, errno via std.os.linux.errno. Zig 0.16.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const Link = @import("list.zig").Link;
const Signal = @import("signal.zig").Signal;
const EventLoop = @import("event_loop.zig").EventLoop;
const EventSource = @import("event_loop.zig").EventSource;
const event_loop = @import("event_loop.zig");
const Client = @import("server_client.zig").Client;
const interface = @import("interface.zig");
const Interface = interface.Interface;
const global_mod = @import("global.zig");
const Global = global_mod.Global;
const BindFn = global_mod.BindFn;

const LOCK_EX: i32 = 2;
const LOCK_NB: i32 = 4;

pub const DisplayError = error{
    OutOfMemory,
    SocketCreateFailed,
    SocketBindFailed,
    SocketListenFailed,
    LockFailed,
    NoFreeSocket,
    XdgRuntimeDirNotSet,
    NameTooLong,
    EventLoopFailed,
};

/// One listening socket bound to the display's event loop.
const SocketListener = struct {
    display: *Display,
    fd: i32,
    source: *EventSource,
    link: Link,
    /// The lockfile fd (libwayland holds a flock on <name>.lock), or -1.
    lock_fd: i32 = -1,
    /// Owned copy of the bound socket path (for unlink on destroy), or empty.
    path_buf: [108]u8 = undefined,
    path_len: usize = 0,

    fn boundPath(self: *const SocketListener) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

pub const Display = struct {
    allocator: std.mem.Allocator,
    loop: *EventLoop,
    owns_loop: bool,

    client_list: Link,
    global_list: Link,

    socket_list: Link,

    serial: u32,
    /// Monotonic registry-name allocator for globals (starts at 1).
    next_global_name: u32,
    running: bool,

    destroy_signal: Signal,
    client_created_signal: Signal,

    /// Create a display owning a fresh event loop. Mirrors wl_display_create.
    pub fn create(allocator: std.mem.Allocator) DisplayError!*Display {
        const loop = EventLoop.create(allocator) catch return error.EventLoopFailed;
        errdefer loop.destroy();
        const self = try createWithLoop(allocator, loop, true);
        return self;
    }

    /// Create a display borrowing an existing event loop (the caller keeps
    /// ownership of `loop`). Useful when embedding in a larger poll set.
    pub fn createWithLoop(
        allocator: std.mem.Allocator,
        loop: *EventLoop,
        owns_loop: bool,
    ) DisplayError!*Display {
        const self = try allocator.create(Display);
        self.* = .{
            .allocator = allocator,
            .loop = loop,
            .owns_loop = owns_loop,
            .client_list = undefined,
            .global_list = undefined,
            .socket_list = undefined,
            .serial = 0,
            .next_global_name = 1,
            .running = false,
            .destroy_signal = undefined,
            .client_created_signal = undefined,
        };
        self.client_list.init();
        self.global_list.init();
        self.socket_list.init();
        self.destroy_signal.init();
        self.client_created_signal.init();
        return self;
    }

    /// Destroy the display: fire the destroy signal, destroy all clients, close
    /// and unlink all sockets, free the loop if owned. Mirrors
    /// wl_display_destroy.
    pub fn destroy(self: *Display) void {
        self.destroy_signal.emit(self);

        // Destroy clients (each removes itself from client_list).
        var cit = self.client_list.iterator(Client, "link");
        while (cit.next()) |client| {
            client.destroy();
        }

        // Tear down sockets.
        var sit = self.socket_list.iterator(SocketListener, "link");
        while (sit.next()) |sock| {
            self.loop.eventSourceRemove(sock.source);
            _ = linux.close(sock.fd);
            const p = sock.boundPath();
            if (p.len > 0) {
                var z: [109]u8 = undefined;
                @memcpy(z[0..p.len], p);
                z[p.len] = 0;
                _ = linux.unlink(@ptrCast(&z));
            }
            if (sock.lock_fd >= 0) {
                _ = linux.close(sock.lock_fd);
                // remove the .lock file too
                if (p.len > 0 and p.len + 5 < 109) {
                    var z: [114]u8 = undefined;
                    @memcpy(z[0..p.len], p);
                    @memcpy(z[p.len .. p.len + 5], ".lock");
                    z[p.len + 5] = 0;
                    _ = linux.unlink(@ptrCast(&z));
                }
            }
            sock.link.remove();
            self.allocator.destroy(sock);
        }

        // Free any remaining globals (clients are gone, so no advertisement).
        var git = self.global_list.iterator(Global, "link");
        while (git.next()) |g| {
            g.link.remove();
            self.allocator.destroy(g);
        }

        const allocator = self.allocator;
        const loop = self.loop;
        const owns = self.owns_loop;
        allocator.destroy(self);
        if (owns) loop.destroy();
    }

    /// The display's event loop. Mirrors wl_display_get_event_loop.
    pub fn getEventLoop(self: *Display) *EventLoop {
        return self.loop;
    }

    /// Next event serial (post-increment, wrapping). Mirrors
    /// wl_display_next_serial.
    pub fn nextSerial(self: *Display) u32 {
        self.serial +%= 1;
        return self.serial;
    }

    /// Current event serial (last issued). Mirrors wl_display_get_serial.
    pub fn getSerial(self: *const Display) u32 {
        return self.serial;
    }

    /// Create + advertise a global. Assigns a monotonic registry name, adds it
    /// to the global_list, and posts wl_registry.global to every client's bound
    /// registries. Mirrors wl_global_create. The returned Global is owned by the
    /// display (freed by Global.destroy or Display.destroy).
    pub fn globalCreate(
        self: *Display,
        iface: *const Interface,
        version: u32,
        bind_fn: BindFn,
        data: ?*anyopaque,
    ) DisplayError!*Global {
        const g = self.allocator.create(Global) catch return error.OutOfMemory;
        g.* = .{
            .interface = iface,
            .version = version,
            .bind = bind_fn,
            .data = data,
            .name = self.next_global_name,
            .link = undefined,
            .display = self,
        };
        self.next_global_name += 1;
        g.link.init();
        self.global_list.append(&g.link);

        // Advertise to every client's bound registries.
        var cit = self.client_list.iterator(Client, "link");
        while (cit.next()) |client| {
            var rit = client.registry_list.iterator(@import("server_client.zig").Object, "registry_link");
            while (rit.next()) |reg| {
                reg.postEvent(interface.REGISTRY_GLOBAL, &.{
                    .{ .uint = g.name },
                    .{ .string = g.interface.name },
                    .{ .uint = g.version },
                }) catch {};
            }
        }
        return g;
    }

    /// Post wl_registry.global_remove(name) to every client's bound registries.
    /// Called by Global.destroy.
    pub fn advertiseGlobalRemove(self: *Display, name: u32) void {
        const Object = @import("server_client.zig").Object;
        var cit = self.client_list.iterator(Client, "link");
        while (cit.next()) |client| {
            var rit = client.registry_list.iterator(Object, "registry_link");
            while (rit.next()) |reg| {
                reg.postEvent(interface.REGISTRY_GLOBAL_REMOVE, &.{.{ .uint = name }}) catch {};
            }
        }
    }

    /// Bind a listening socket at $XDG_RUNTIME_DIR/<name> with a <name>.lock
    /// lockfile, add it to the event loop. Mirrors wl_display_add_socket.
    pub fn addSocket(self: *Display, name: []const u8) DisplayError!void {
        const rt = std.posix.getenv("XDG_RUNTIME_DIR") orelse return error.XdgRuntimeDirNotSet;
        return self.addSocketInDir(rt, name);
    }

    /// Like addSocket but with an explicit runtime directory (used by tests).
    pub fn addSocketInDir(self: *Display, dir: []const u8, name: []const u8) DisplayError!void {
        var path_buf: [108]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return error.NameTooLong;
        if (path.len >= 108) return error.NameTooLong;

        // Lockfile: <path>.lock, flock LOCK_EX|LOCK_NB.
        var lock_buf: [114]u8 = undefined;
        const lock_path = std.fmt.bufPrintZ(&lock_buf, "{s}.lock", .{path}) catch return error.NameTooLong;
        const lock_fd = openLock(lock_path) catch return error.LockFailed;
        errdefer _ = linux.close(lock_fd);
        if (linux.flock(lock_fd, LOCK_EX | LOCK_NB) != 0) {
            _ = linux.close(lock_fd);
            return error.LockFailed;
        }

        // Stale socket: unlink if present (we hold the lock, so it is ours).
        var zpath: [109]u8 = undefined;
        @memcpy(zpath[0..path.len], path);
        zpath[path.len] = 0;
        _ = linux.unlink(@ptrCast(&zpath));

        const fd = try makeListenSocket(path);
        errdefer _ = linux.close(fd);

        try self.adoptListenFd(fd, path, lock_fd);
    }

    /// Try wayland-0 .. wayland-31, binding the first free one. Returns the name
    /// chosen (a slice into `out_name`, which the caller owns). Mirrors
    /// wl_display_add_socket_auto.
    pub fn addSocketAuto(self: *Display, out_name: *[16]u8) DisplayError![]const u8 {
        const rt = std.posix.getenv("XDG_RUNTIME_DIR") orelse return error.XdgRuntimeDirNotSet;
        return self.addSocketAutoInDir(rt, out_name);
    }

    /// Like addSocketAuto but with an explicit runtime directory (used by tests).
    pub fn addSocketAutoInDir(self: *Display, dir: []const u8, out_name: *[16]u8) DisplayError![]const u8 {
        var i: u32 = 0;
        while (i <= 32) : (i += 1) {
            const name = std.fmt.bufPrint(out_name, "wayland-{d}", .{i}) catch return error.NameTooLong;
            self.addSocketInDir(dir, name) catch |e| {
                if (e == error.LockFailed or e == error.SocketBindFailed) continue;
                return e;
            };
            return name;
        }
        return error.NoFreeSocket;
    }

    /// Adopt an already-listening fd as a socket source. Mirrors
    /// wl_display_add_socket_fd. The fd must be a listening SOCK_STREAM.
    pub fn addSocketFd(self: *Display, fd: i32) DisplayError!void {
        try self.adoptListenFd(fd, "", -1);
    }

    fn adoptListenFd(self: *Display, fd: i32, path: []const u8, lock_fd: i32) DisplayError!void {
        const sock = try self.allocator.create(SocketListener);
        errdefer self.allocator.destroy(sock);
        sock.* = .{
            .display = self,
            .fd = fd,
            .source = undefined,
            .link = undefined,
            .lock_fd = lock_fd,
        };
        if (path.len > 0) {
            @memcpy(sock.path_buf[0..path.len], path);
            sock.path_len = path.len;
        }
        sock.link.init();
        sock.source = self.loop.addFd(fd, event_loop.READABLE, socketReadable, sock) catch
            return error.EventLoopFailed;
        self.socket_list.append(&sock.link);
    }

    /// Event-loop callback for a listening socket becoming readable: accept all
    /// pending connections and create a Client for each.
    fn socketReadable(fd: i32, mask: u32, data: ?*anyopaque) callconv(.c) c_int {
        _ = mask;
        const sock: *SocketListener = @ptrCast(@alignCast(data.?));
        const display = sock.display;
        // Accept in a loop (level-triggered, but a burst may queue several).
        while (true) {
            // SOCK_CLOEXEC | SOCK_NONBLOCK on the accepted fd via accept4.
            const flags: u32 = linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK;
            const rc = linux.accept4(fd, null, null, flags);
            const e = std.os.linux.errno(rc);
            if (e != .SUCCESS) {
                // EAGAIN: drained. Anything else: stop for now.
                break;
            }
            const cfd: i32 = @intCast(rc);
            _ = Client.create(display, cfd) catch {
                _ = linux.close(cfd);
                continue;
            };
        }
        return 1;
    }

    /// Flush every client's outgoing connection. Mirrors wl_display_flush_clients.
    pub fn flushClients(self: *Display) void {
        var it = self.client_list.iterator(Client, "link");
        while (it.next()) |client| {
            client.flush() catch {};
        }
    }

    /// Run the dispatch loop until terminate() is called. Mirrors wl_display_run.
    pub fn run(self: *Display) void {
        self.running = true;
        while (self.running) {
            self.flushClients();
            self.loop.dispatch(-1) catch break;
        }
    }

    /// Stop the run loop. Mirrors wl_display_terminate.
    pub fn terminate(self: *Display) void {
        self.running = false;
    }
};

fn openLock(path_z: [:0]const u8) !i32 {
    // O_CREAT | O_CLOEXEC | O_RDWR, mode 0660. linux.O is a packed struct here.
    const O = linux.O{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true };
    const rc = linux.open(path_z.ptr, O, 0o660);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.LockFailed;
    return @intCast(rc);
}

fn makeListenSocket(path: []const u8) DisplayError!i32 {
    const rc = linux.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
    );
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketCreateFailed;
    const fd: i32 = @intCast(rc);
    errdefer _ = linux.close(fd);

    var addr = linux.sockaddr.un{ .family = linux.AF.UNIX, .path = std.mem.zeroes([108]u8) };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);

    // sun_family + the path bytes + the NUL.
    const addrlen: linux.socklen_t = @intCast(@sizeOf(linux.sa_family_t) + path.len + 1);
    const brc = linux.bind(fd, @ptrCast(&addr), addrlen);
    if (std.os.linux.errno(brc) != .SUCCESS) return error.SocketBindFailed;

    const lrc = linux.listen(fd, 128);
    if (std.os.linux.errno(lrc) != .SUCCESS) return error.SocketListenFailed;

    return fd;
}

const testing = std.testing;

test "Display: create, serial counter, destroy" {
    const d = try Display.create(testing.allocator);
    defer d.destroy();

    try testing.expectEqual(@as(u32, 0), d.getSerial());
    try testing.expectEqual(@as(u32, 1), d.nextSerial());
    try testing.expectEqual(@as(u32, 2), d.nextSerial());
    try testing.expectEqual(@as(u32, 2), d.getSerial());
    try testing.expect(d.getEventLoop().getFd() >= 0);
    try testing.expect(d.client_list.empty());
}

test "Display: addSocketAuto binds in a temp runtime dir" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];

    const d = try Display.create(testing.allocator);
    defer d.destroy();

    var name_buf: [16]u8 = undefined;
    const name = try d.addSocketAutoInDir(dir, &name_buf);
    try testing.expect(std.mem.startsWith(u8, name, "wayland-"));
    try testing.expect(!d.socket_list.empty());

    // The socket file exists at <dir>/<name> (F_OK = mode 0).
    var full_buf: [300]u8 = undefined;
    const full = try std.fmt.bufPrintZ(&full_buf, "{s}/{s}", .{ dir, name });
    try testing.expect(std.os.linux.errno(linux.access(full.ptr, 0)) == .SUCCESS);
}
