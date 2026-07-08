//! wl_shm at libwayland parity: the shared-memory global plus its pool and
//! buffer objects.
//!
//! Mirrors libwayland's src/wayland-shm.c (wl_shm / wl_shm_pool / wl_buffer).
//! A client binds wl_shm, receives the supported format events, then:
//!   create_pool(new_id, fd, size) -> the server mmaps `fd` and tracks a Pool
//!   wl_shm_pool.create_buffer(new_id, offset, w, h, stride, format) -> a Buffer
//!     that references a window into the pool's mapping
//!   wl_shm_pool.resize(size) / destroy, wl_buffer.destroy
//!
//! The `fd` of create_pool arrives out-of-band over SCM_RIGHTS (the 'h'
//! signature char): the runtime demarshals it off the Connection's incoming fd
//! queue, so the generated dispatch hands us a ready-to-mmap descriptor.
//!
//! This module is generic over the generated protocol bindings (WlShm /
//! WlShmPool / WlBuffer) so it carries zero baked-in protocol: a consumer wires
//! it up with `Shm(Protocol).create(display)`. The pool/buffer pixel data is
//! exposed so a compositor can sample a committed buffer and send wl_buffer
//! .release back.
//!
//! Raw Linux syscalls via std.os.linux, errno via std.os.linux.errno. Zig 0.16
//! (std.os.linux mmap/munmap/mremap/close).

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const Display = @import("display.zig").Display;
const Client = @import("server_client.zig").Client;
const Object = @import("server_client.zig").Object;
const Global = @import("global.zig").Global;

/// ftruncate syscall wrapper (std.posix.ftruncate was removed in 0.16).
fn ftruncate(fd: posix.fd_t, length: i64) !void {
    const rc = linux.ftruncate(fd, length);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.TruncateFailed;
}

/// A client-side, mmap'd SHM pool backed by a memfd. Used by a Wayland client
/// to back wl_shm buffers it sends to a compositor. The server side (this
/// server's wl_shm) maps the client's fd via `Pool` below.
pub const ShmPool = struct {
    fd: posix.fd_t,
    size: usize,
    data: []align(std.heap.page_size_min) u8,

    /// Create a memfd of `size` bytes and mmap it read-write.
    pub fn create(size: usize) !ShmPool {
        const fd = try posix.memfd_create("wayland-shm", 0);
        errdefer closeFd(fd);
        try ftruncate(fd, @intCast(size));
        const data = try std.posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        return ShmPool{ .fd = fd, .size = size, .data = data };
    }

    pub fn deinit(self: *ShmPool) void {
        std.posix.munmap(self.data);
        closeFd(self.fd);
        self.* = undefined;
    }
};

/// Send `wire_buf` bytes as the normal data payload plus `fd` as SCM_RIGHTS
/// ancillary. `sock_fd` must be a connected Unix domain socket. Client-side
/// helper (the server receives fds via its buffered Connection).
pub fn sendFd(sock_fd: posix.fd_t, wire_buf: []const u8, fd: posix.fd_t) !void {
    const system = std.posix.system;
    const Cmsghdr = system.cmsghdr;

    const hdr_size = @sizeOf(Cmsghdr);
    const fd_size = @sizeOf(posix.fd_t);
    const cmsg_buf_size = hdr_size + fd_size;

    var cmsg_buf: [64]u8 align(8) = std.mem.zeroes([64]u8);
    const cmsg: *Cmsghdr = @ptrCast(@alignCast(&cmsg_buf));
    cmsg.len = cmsg_buf_size;
    cmsg.level = std.posix.SOL.SOCKET;
    cmsg.type = std.posix.SCM.RIGHTS;
    const fd_ptr: *posix.fd_t = @ptrCast(@alignCast(cmsg_buf[hdr_size..].ptr));
    fd_ptr.* = fd;

    var iov = std.posix.iovec_const{
        .base = wire_buf.ptr,
        .len = wire_buf.len,
    };

    const msg = std.posix.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&iov),
        .iovlen = 1,
        .control = &cmsg_buf,
        .controllen = cmsg_buf_size,
        .flags = 0,
    };

    const rc = system.sendmsg(sock_fd, &msg, 0);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SendFailed;
}

/// The two formats every shm renderer must support (wl_shm.format values).
pub const FORMAT_ARGB8888: u32 = 0;
pub const FORMAT_XRGB8888: u32 = 1;

/// wl_shm.error codes (src/wayland-shm.c).
pub const ShmError = struct {
    pub const invalid_format: u32 = 0;
    pub const invalid_stride: u32 = 1;
    pub const invalid_fd: u32 = 2;
};

/// close wrapper (std.posix.close was removed in 0.16).
fn closeFd(fd: posix.fd_t) void {
    _ = linux.close(fd);
}

/// mmap a descriptor PROT_READ, MAP_SHARED. Returns the mapping slice or an
/// error. Used by the server to map a client-provided pool fd.
fn mmapRead(fd: posix.fd_t, size: usize) ![]align(std.heap.page_size_min) u8 {
    const rc = linux.mmap(
        null,
        size,
        .{ .READ = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    const e = std.os.linux.errno(rc);
    if (e != .SUCCESS) return error.MmapFailed;
    const ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(rc);
    return ptr[0..size];
}

fn munmap(data: []align(std.heap.page_size_min) const u8) void {
    _ = linux.munmap(data.ptr, data.len);
}

/// A wl_shm_pool: a single read-only mapping of a client fd, refcounted by the
/// pool resource itself plus every buffer created from it (libwayland keeps the
/// mapping alive until the pool is destroyed AND all its buffers are gone).
pub const Pool = struct {
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    data: []align(std.heap.page_size_min) u8,
    size: usize,
    /// 1 (the pool resource) + one per live buffer.
    refcount: usize,

    fn create(allocator: std.mem.Allocator, fd: posix.fd_t, size: usize) !*Pool {
        const data = try mmapRead(fd, size);
        errdefer munmap(data);
        const self = try allocator.create(Pool);
        self.* = .{
            .allocator = allocator,
            .fd = fd,
            .data = data,
            .size = size,
            .refcount = 1,
        };
        return self;
    }

    fn ref(self: *Pool) void {
        self.refcount += 1;
    }

    /// Drop a reference. When it hits 0 the mapping is unmapped, the fd closed,
    /// and the Pool freed.
    fn unref(self: *Pool) void {
        self.refcount -= 1;
        if (self.refcount == 0) {
            munmap(self.data);
            closeFd(self.fd);
            const allocator = self.allocator;
            allocator.destroy(self);
        }
    }

    /// Remap the pool to a larger size (wl_shm_pool.resize). The kernel
    /// mremap keeps the contents and may move the mapping. Shrinking is a
    /// protocol error in libwayland, so only growth is honored.
    fn resize(self: *Pool, new_size: usize) !void {
        if (new_size <= self.size) {
            // Nothing to grow; libwayland only ever enlarges. Treat a no-op /
            // smaller request as a benign keep-current (the spec forbids
            // shrinking, the client must not rely on it).
            return;
        }
        // MREMAP_MAYMOVE = 1.
        const rc = linux.mremap(self.data.ptr, self.size, new_size, .{ .MAYMOVE = true }, null);
        const e = std.os.linux.errno(rc);
        if (e != .SUCCESS) return error.MremapFailed;
        const ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(rc);
        self.data = ptr[0..new_size];
        self.size = new_size;
    }
};

/// A wl_buffer backed by a window into a Pool. The compositor reads pixels from
/// `pool.data[offset..]` with the given stride; nothing here ever writes the
/// client's memory (it is mapped PROT_READ).
pub const Buffer = struct {
    allocator: std.mem.Allocator,
    pool: *Pool,
    offset: i32,
    width: i32,
    height: i32,
    stride: i32,
    format: u32,

    /// The buffer's pixels as a read-only slice (pool.data + offset, length
    /// stride*height). The compositor samples this to composite the surface.
    pub fn pixels(self: *const Buffer) []const u8 {
        const start: usize = @intCast(self.offset);
        const len: usize = @intCast(self.stride * self.height);
        return self.pool.data[start .. start + len];
    }

    fn destroy(self: *Buffer) void {
        const allocator = self.allocator;
        self.pool.unref();
        allocator.destroy(self);
    }
};

/// The set of advertised formats (always at least ARGB8888 + XRGB8888).
pub const default_formats = [_]u32{ FORMAT_ARGB8888, FORMAT_XRGB8888 };

/// Build a reusable wl_shm helper over the generated protocol bindings.
/// `Protocol` must expose `WlShm`, `WlShmPool`, `WlBuffer` (the generator
/// output of wayland.xml). Usage:
///
///   const Shm = wl.shm.Shm(wayland_protocol);
///   const shm = try Shm.create(display);
///
pub fn Shm(comptime Protocol: type) type {
    return struct {
        const Self = @This();
        const WlShm = Protocol.WlShm;
        const WlShmPool = Protocol.WlShmPool;
        const WlBuffer = Protocol.WlBuffer;

        display: *Display,
        /// Cached at create so deinit does not reach through `display`, which the
        /// owner may already have destroyed.
        allocator: std.mem.Allocator,
        global: *Global,
        formats: []const u32,
        shm_impl: WlShm.Implementation,
        pool_impl: WlShmPool.Implementation,
        buffer_impl: WlBuffer.Implementation,

        /// Create + advertise the wl_shm global. The helper is heap-allocated so
        /// its address is stable for the bind callback's user_data.
        pub fn create(display: *Display) !*Self {
            return createWithFormats(display, &default_formats);
        }

        /// Like create but with an explicit advertised format list (must include
        /// ARGB8888 + XRGB8888 for a conforming server).
        pub fn createWithFormats(display: *Display, formats: []const u32) !*Self {
            const self = try display.allocator.create(Self);
            errdefer display.allocator.destroy(self);
            self.* = .{
                .display = display,
                .allocator = display.allocator,
                .global = undefined,
                .formats = formats,
                .shm_impl = .{ .create_pool = onCreatePool, .release = onShmRelease },
                .pool_impl = .{
                    .create_buffer = onCreateBuffer,
                    .destroy = onPoolDestroy,
                    .resize = onPoolResize,
                },
                .buffer_impl = .{ .destroy = onBufferDestroy },
            };
            self.global = try display.globalCreate(
                &WlShm.interface,
                WlShm.version,
                bindShm,
                self,
            );
            return self;
        }

        /// Free the helper. Safe to call after Display.destroy. The global it
        /// registered is owned by the display, which frees remaining globals on
        /// destroy.
        pub fn deinit(self: *Self) void {
            self.allocator.destroy(self);
        }

        /// wl_shm bind: create the resource, attach the implementation, and send
        /// every supported format. Mirrors bind_shm in src/wayland-shm.c.
        fn bindShm(client: *Client, data: ?*anyopaque, version: u32, id: u32) void {
            const self: *Self = @ptrCast(@alignCast(data.?));
            const resource = Object.create(client, &WlShm.interface, version, id) catch return;
            WlShm.setImplementation(resource, &self.shm_impl, self, null);
            for (self.formats) |fmt| {
                WlShm.sendFormat(resource, fmt);
            }
        }

        /// wl_shm.create_pool(new_id, fd, size). The fd has already been pulled
        /// off the SCM_RIGHTS queue by the generated dispatch. mmap it and wrap
        /// it in a Pool; create the wl_shm_pool resource referencing it.
        fn onCreatePool(client_data: ?*anyopaque, resource: *Object, id: u32, fd: i32, size: i32) void {
            const self: *Self = @ptrCast(@alignCast(client_data.?));
            const client = resource.client;

            if (size <= 0) {
                closeFd(fd);
                resource.postError(ShmError.invalid_stride, "invalid pool size {d}", .{size});
                return;
            }

            const pool = Pool.create(self.display.allocator, fd, @intCast(size)) catch {
                closeFd(fd);
                resource.postError(ShmError.invalid_fd, "failed to map pool fd", .{});
                return;
            };

            const pool_res = Object.create(client, &WlShmPool.interface, resource.version, id) catch {
                pool.unref();
                return;
            };
            WlShmPool.setImplementation(pool_res, &self.pool_impl, pool, poolResourceDestroyed);
        }

        /// wl_shm.release (v2 destructor): drop the wl_shm resource.
        fn onShmRelease(client_data: ?*anyopaque, resource: *Object) void {
            _ = client_data;
            resource.destroy();
        }

        /// wl_shm_pool.create_buffer: validate format + bounds, then create a
        /// wl_buffer that references a window into the pool. Mirrors
        /// shm_pool_create_buffer in src/wayland-shm.c.
        fn onCreateBuffer(
            client_data: ?*anyopaque,
            resource: *Object,
            id: u32,
            offset: i32,
            width: i32,
            height: i32,
            stride: i32,
            format: u32,
        ) void {
            // The pool resource's user_data (and so client_data) is the Pool,
            // not the helper. Recover the helper from the resource's
            // implementation, which is &Self.pool_impl.
            _ = client_data;
            const pool: *Pool = @ptrCast(@alignCast(resource.user_data.?));
            const impl: *const WlShmPool.Implementation = @ptrCast(@alignCast(resource.implementation.?));
            const self: *const Self = @alignCast(@fieldParentPtr("pool_impl", impl));
            const client = resource.client;

            // Format must be one we advertised.
            var ok_format = false;
            for (self.formats) |fmt| {
                if (fmt == format) ok_format = true;
            }
            if (!ok_format) {
                resource.postError(ShmError.invalid_format, "unsupported format {x}", .{format});
                return;
            }

            // Geometry + bounds validation, matching libwayland's checks.
            if (offset < 0 or width <= 0 or height <= 0 or stride <= 0) {
                resource.postError(ShmError.invalid_stride, "invalid buffer geometry", .{});
                return;
            }
            if (stride < width) {
                resource.postError(ShmError.invalid_stride, "stride {d} < width {d}", .{ stride, width });
                return;
            }
            // offset + stride*height must fit within the pool, with overflow care.
            const stride_h = @mulWithOverflow(stride, height);
            if (stride_h[1] != 0) {
                resource.postError(ShmError.invalid_stride, "stride*height overflow", .{});
                return;
            }
            const end = @addWithOverflow(offset, stride_h[0]);
            if (end[1] != 0 or @as(usize, @intCast(end[0])) > pool.size) {
                resource.postError(ShmError.invalid_stride, "buffer extends past pool", .{});
                return;
            }

            const buffer = self.display.allocator.create(Buffer) catch return;
            buffer.* = .{
                .allocator = self.display.allocator,
                .pool = pool,
                .offset = offset,
                .width = width,
                .height = height,
                .stride = stride,
                .format = format,
            };
            pool.ref();

            const buf_res = Object.create(client, &WlBuffer.interface, 1, id) catch {
                buffer.destroy();
                return;
            };
            WlBuffer.setImplementation(buf_res, &self.buffer_impl, buffer, bufferResourceDestroyed);
        }

        /// wl_shm_pool.resize(size): grow the mapping.
        fn onPoolResize(client_data: ?*anyopaque, resource: *Object, size: i32) void {
            _ = client_data;
            const pool: *Pool = @ptrCast(@alignCast(resource.user_data.?));
            if (size <= 0) {
                resource.postError(ShmError.invalid_stride, "invalid resize {d}", .{size});
                return;
            }
            pool.resize(@intCast(size)) catch {
                resource.postError(ShmError.invalid_fd, "failed to remap pool", .{});
            };
        }

        /// wl_shm_pool.destroy (destructor): drop the pool resource. The
        /// underlying mapping survives while buffers still reference it (the
        /// resource-destroyed hook drops the pool's own reference).
        fn onPoolDestroy(client_data: ?*anyopaque, resource: *Object) void {
            _ = client_data;
            resource.destroy();
        }

        /// wl_buffer.destroy (destructor).
        fn onBufferDestroy(client_data: ?*anyopaque, resource: *Object) void {
            _ = client_data;
            resource.destroy();
        }

        fn poolResourceDestroyed(resource: *Object) void {
            const pool: *Pool = @ptrCast(@alignCast(resource.user_data.?));
            pool.unref();
        }

        fn bufferResourceDestroyed(resource: *Object) void {
            const buffer: *Buffer = @ptrCast(@alignCast(resource.user_data.?));
            buffer.destroy();
        }

        /// Send wl_buffer.release on a buffer resource (compositor done sampling).
        pub fn releaseBuffer(buffer_resource: *Object) void {
            WlBuffer.sendRelease(buffer_resource);
        }
    };
}

const testing = std.testing;

/// memfd_create wrapper for tests (a real shm fd to hand to create_pool).
fn memfd(size: usize) !posix.fd_t {
    const fd = try posix.memfd_create("wayland-shm-test", 0);
    const rc = linux.ftruncate(fd, @intCast(size));
    if (std.os.linux.errno(rc) != .SUCCESS) {
        closeFd(fd);
        return error.TruncateFailed;
    }
    return fd;
}

test "shm Pool: map a memfd, refcount, resize, unref" {
    const fd = try memfd(4096);
    const pool = try Pool.create(testing.allocator, fd, 4096);
    try testing.expectEqual(@as(usize, 4096), pool.size);
    try testing.expectEqual(@as(usize, 1), pool.refcount);

    // The mapping is readable; the memfd was zero-filled.
    try testing.expectEqual(@as(u8, 0), pool.data[0]);

    pool.ref();
    try testing.expectEqual(@as(usize, 2), pool.refcount);

    // Grow the backing file before remapping, as a real client does (it
    // ftruncates its memfd, then sends wl_shm_pool.resize). resize only remaps;
    // without growing the file the pages past the old EOF are unbacked and
    // touching them is a SIGBUS (masked on arches with pages larger than 4K).
    try ftruncate(fd, 8192);
    try pool.resize(8192);
    try testing.expectEqual(@as(usize, 8192), pool.size);
    try testing.expectEqual(@as(u8, 0), pool.data[8191]);

    pool.unref();
    try testing.expectEqual(@as(usize, 1), pool.refcount);
    pool.unref(); // unmaps + closes fd + frees
}

test "shm Pool: resize never shrinks" {
    const fd = try memfd(8192);
    const pool = try Pool.create(testing.allocator, fd, 8192);
    defer pool.unref();
    try pool.resize(4096); // ignored (would shrink)
    try testing.expectEqual(@as(usize, 8192), pool.size);
}
