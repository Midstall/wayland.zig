//! End-to-end check that the generated server stubs work: a compositor uses the
//! generated `wl_compositor.interface` table + generated dispatch to receive a
//! client's create_surface request and create a wl_surface resource, then uses a
//! generated event sender (wl_surface.sendEnter) to emit an event whose wire
//! bytes the client decodes.
//!
//! The protocol module `wlp` is generated from the canonical wayland.xml at build
//! time (see build.zig). `wl` is the abstract runtime. No event loop is needed:
//! a socketpair gives the client a raw fd, and the server side is driven by
//! pumping the Client's connection + drainMessages directly.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const wl = @import("wayland");
const wlp = @import("wayland_protocol");

const Display = wl.Display;
const Client = wl.server_client.Client;
const Object = wl.Object;

// State the generated dispatch writes into, so the test can assert it fired.
const State = struct {
    created_surface_id: u32 = 0,
    surface: ?*Object = null,
    create_surface_calls: u32 = 0,
};

fn onCreateSurface(client_data: ?*anyopaque, resource: *Object, id: u32) void {
    const state: *State = @ptrCast(@alignCast(client_data.?));
    state.create_surface_calls += 1;
    state.created_surface_id = id;
    // Create the wl_surface resource at the client-supplied new_id using the
    // generated interface table.
    const surface = Object.create(resource.client, &wlp.WlSurface.interface, resource.version, id) catch return;
    state.surface = surface;
}

fn bindCompositor(client: *Client, data: ?*anyopaque, version: u32, id: u32) void {
    // The compositor's bind callback: create the wl_compositor resource via the
    // generated interface and attach the generated implementation + dispatcher.
    const resource = Object.create(client, &wlp.WlCompositor.interface, version, id) catch return;
    const impl_holder: *Impl = @ptrCast(@alignCast(data.?));
    wlp.WlCompositor.setImplementation(resource, &impl_holder.impl, impl_holder.state, null);
}

const Impl = struct {
    impl: wlp.WlCompositor.Implementation,
    state: *State,
};

// Helpers to craft raw client->server request bytes.
fn writeU32(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try buf.appendSlice(gpa, &b);
}

/// Build one wire message: header (object_id, (size<<16)|opcode) + body words.
fn buildMessage(gpa: std.mem.Allocator, object_id: u32, opcode: u16, body: []const u32) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    const size: u32 = @intCast(8 + body.len * 4);
    try writeU32(&buf, gpa, object_id);
    try writeU32(&buf, gpa, (size << 16) | @as(u32, opcode));
    for (body) |word| try writeU32(&buf, gpa, word);
    return buf.toOwnedSlice(gpa);
}

/// Build a string-arg word stream: u32 length-including-NUL, bytes, NUL, padded.
fn appendString(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    const len_with_nul: u32 = @intCast(s.len + 1);
    try writeU32(buf, gpa, len_with_nul);
    try buf.appendSlice(gpa, s);
    try buf.append(gpa, 0);
    // pad to 4
    const total = s.len + 1;
    const pad = (4 - (total % 4)) % 4;
    var i: usize = 0;
    while (i < pad) : (i += 1) try buf.append(gpa, 0);
}

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

test "generated server stubs: wl_compositor.create_surface dispatch + wl_surface.sendEnter roundtrip" {
    const gpa = std.testing.allocator;

    const d = try Display.create(gpa);
    defer d.destroy();

    var state = State{};
    var impl_holder = Impl{
        .impl = .{ .create_surface = onCreateSurface, .create_region = null },
        .state = &state,
    };

    // Register the wl_compositor global using the generated interface table.
    _ = try d.globalCreate(&wlp.WlCompositor.interface, wlp.WlCompositor.version, bindCompositor, &impl_holder);

    // socketpair: [0] is the server-side Client fd, [1] is the raw client.
    const pair = try socketpair();
    const client_fd = pair[1];
    defer _ = linux.close(client_fd);

    const client = try Client.create(d, pair[0]);

    // Object id plan (client-allocated): 2 = wl_registry, 3 = wl_compositor,
    // 4 = wl_surface.
    const registry_id: u32 = 2;
    const compositor_id: u32 = 3;
    const surface_id: u32 = 4;

    // 1) wl_display.get_registry(new_id registry) -> opcode 1, body = [registry_id].
    {
        const msg = try buildMessage(gpa, wl.server_client.DISPLAY_ID, 1, &.{registry_id});
        defer gpa.free(msg);
        try writeAll(client_fd, msg);
    }
    _ = client.conn.read() catch {};
    _ = client.drainMessages();
    try client.flush();

    // The server should have advertised wl_compositor on the registry. Find its
    // global name by reading the events the client received.
    var rbuf: [4096]u8 = undefined;
    const n_adv = try readSome(client_fd, &rbuf);
    const compositor_name = try findGlobalName(rbuf[0..n_adv], registry_id, "wl_compositor");

    // 2) wl_registry.bind(name, interface, version, new_id) -> opcode 0.
    {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);
        try writeU32(&body, gpa, compositor_name); // name (u)
        try appendString(&body, gpa, "wl_compositor"); // interface (s)
        try writeU32(&body, gpa, wlp.WlCompositor.version); // version (u)
        try writeU32(&body, gpa, compositor_id); // new_id (n)

        const size: u32 = @intCast(8 + body.items.len);
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(gpa);
        try writeU32(&msg, gpa, registry_id);
        try writeU32(&msg, gpa, (size << 16) | 0);
        try msg.appendSlice(gpa, body.items);
        try writeAll(client_fd, msg.items);
    }
    _ = client.conn.read() catch {};
    _ = client.drainMessages();
    try client.flush();

    // The compositor resource must now exist server-side with the generated
    // dispatcher installed.
    const comp_obj = client.getObject(compositor_id) orelse return error.NoCompositor;
    try std.testing.expect(comp_obj.dispatcher != null);
    try std.testing.expectEqualStrings("wl_compositor", comp_obj.iface.?.name);

    // 3) wl_compositor.create_surface(new_id surface) -> opcode 0, body = [surface_id].
    {
        const msg = try buildMessage(gpa, compositor_id, 0, &.{surface_id});
        defer gpa.free(msg);
        try writeAll(client_fd, msg);
    }
    _ = client.conn.read() catch {};
    _ = client.drainMessages();
    try client.flush();

    // The generated dispatch must have fired and created the wl_surface.
    try std.testing.expectEqual(@as(u32, 1), state.create_surface_calls);
    try std.testing.expectEqual(surface_id, state.created_surface_id);
    const surface = state.surface orelse return error.NoSurface;
    try std.testing.expectEqualStrings("wl_surface", surface.iface.?.name);
    try std.testing.expect(client.getObject(surface_id) != null);

    // 4) Use the generated event sender wl_surface.sendEnter(output). We need an
    // output object to reference; fabricate a server resource to act as one.
    const output = try Object.create(client, &wlp.WlOutput.interface, 1, client.allocServerId());
    wlp.WlSurface.sendEnter(surface, output);
    try client.flush();

    // Read the event the client receives and assert the wire bytes: it is
    // wl_surface.enter(output) -> object_id=surface_id, opcode=0 (enter),
    // body = [output.id].
    var ebuf: [256]u8 = undefined;
    const n_ev = try readSome(client_fd, &ebuf);
    try std.testing.expect(n_ev >= 12);
    const ev_obj = std.mem.readInt(u32, ebuf[0..4], .little);
    const ev_word1 = std.mem.readInt(u32, ebuf[4..8], .little);
    const ev_size: u16 = @truncate(ev_word1 >> 16);
    const ev_opcode: u16 = @truncate(ev_word1);
    const ev_arg = std.mem.readInt(u32, ebuf[8..12], .little);

    try std.testing.expectEqual(surface_id, ev_obj);
    try std.testing.expectEqual(@as(u16, 0), ev_opcode); // enter is event opcode 0
    try std.testing.expectEqual(@as(u16, 12), ev_size); // header(8) + one object word
    try std.testing.expectEqual(output.id, ev_arg);
}

/// Read whatever bytes are currently available (the peer already wrote+flushed).
fn readSome(fd: i32, buf: []u8) !usize {
    const rc = linux.read(fd, buf.ptr, buf.len);
    if (posix.errno(rc) != .SUCCESS) return error.ReadFailed;
    return @intCast(rc);
}

/// Scan a byte stream of wl_registry.global(name, interface, version) events for
/// the one advertising `want` and return its registry name. global is event
/// opcode 0 on the registry, signature "usu".
fn findGlobalName(stream: []const u8, registry_id: u32, want: []const u8) !u32 {
    var off: usize = 0;
    while (off + 8 <= stream.len) {
        const obj = std.mem.readInt(u32, stream[off..][0..4], .little);
        const word1 = std.mem.readInt(u32, stream[off + 4 ..][0..4], .little);
        const size: u16 = @truncate(word1 >> 16);
        const opcode: u16 = @truncate(word1);
        if (size < 8 or off + size > stream.len) break;
        const body = stream[off + 8 .. off + size];
        if (obj == registry_id and opcode == 0) {
            // body = name(u32), string(len u32 + bytes + nul + pad), version(u32)
            const name = std.mem.readInt(u32, body[0..4], .little);
            const slen = std.mem.readInt(u32, body[4..8], .little);
            if (slen >= 1 and 8 + slen - 1 <= body.len) {
                const str = body[8 .. 8 + slen - 1]; // drop the NUL
                if (std.mem.eql(u8, str, want)) return name;
            }
        }
        off += size;
    }
    return error.GlobalNotFound;
}
