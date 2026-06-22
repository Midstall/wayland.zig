//! End-to-end test of the Wayland HDR signaling layer: a client negotiates
//! PQ + Rec.2020 HDR with a compositor built on ColorManager(CM).
//!
//! The test stands up a Display with a wp_color_manager_v1 global (via the
//! ColorManager helper), then drives a raw client over a socketpair:
//!   1. bind wp_color_manager_v1, drain the supported_* events, assert that
//!      st2084_pq (PQ) + bt2020 (Rec.2020) + the parametric feature are
//!      advertised and that `done` terminates the advertisement.
//!   2. create_parametric_creator -> set_tf_named(st2084_pq),
//!      set_primaries_named(bt2020), set_mastering_luminance(min 0.005, max
//!      1000 nits) -> create -> assert the image description posts `ready2`.
//!   3. get_surface(a wl_surface) + set_image_description(that desc, perceptual)
//!      -> assert the server stored the per-surface HDR state, with no protocol
//!      error on the connection.
//!
//! No event loop: a socketpair gives the client a raw fd, and the server is
//! pumped directly (conn.read + drainMessages + flush), the same as
//! generated_server_roundtrip.zig.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const wl = @import("wayland");
const wlp = @import("wayland_protocol");
const cmp = @import("color_management_protocol");
const color_management = @import("color_management");

const Display = wl.Display;
const Client = wl.server_client.Client;
const Object = wl.Object;
const ColorManager = color_management.ColorManager(cmp);
const CMConst = color_management;

// Manager event opcodes.
const EV_SUPPORTED_INTENT: u16 = 0;
const EV_SUPPORTED_FEATURE: u16 = 1;
const EV_SUPPORTED_TF_NAMED: u16 = 2;
const EV_SUPPORTED_PRIMARIES_NAMED: u16 = 3;
const EV_DONE: u16 = 4;

// Manager request opcodes.
const REQ_GET_SURFACE: u16 = 2;
const REQ_CREATE_PARAMETRIC_CREATOR: u16 = 5;

// Params creator request opcodes.
const PARAMS_CREATE: u16 = 0;
const PARAMS_SET_TF_NAMED: u16 = 1;
const PARAMS_SET_PRIMARIES_NAMED: u16 = 3;
const PARAMS_SET_MASTERING_LUMINANCE: u16 = 7;

// Surface request opcodes.
const SURFACE_SET_IMAGE_DESCRIPTION: u16 = 1;

// Image-description event opcodes.
const IMG_EV_FAILED: u16 = 0;
const IMG_EV_READY: u16 = 1;
const IMG_EV_READY2: u16 = 2;

// wl_display.error is event opcode 0 on object id 1.

fn writeU32(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try buf.appendSlice(gpa, &b);
}

fn buildMessage(gpa: std.mem.Allocator, object_id: u32, opcode: u16, body: []const u32) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    const size: u32 = @intCast(8 + body.len * 4);
    try writeU32(&buf, gpa, object_id);
    try writeU32(&buf, gpa, (size << 16) | @as(u32, opcode));
    for (body) |word| try writeU32(&buf, gpa, word);
    return buf.toOwnedSlice(gpa);
}

fn appendString(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    const len_with_nul: u32 = @intCast(s.len + 1);
    try writeU32(buf, gpa, len_with_nul);
    try buf.appendSlice(gpa, s);
    try buf.append(gpa, 0);
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

fn readSome(fd: i32, buf: []u8) usize {
    const rc = linux.read(fd, buf.ptr, buf.len);
    if (posix.errno(rc) != .SUCCESS) return 0;
    return @intCast(rc);
}

/// Pump one client->server message: write it, let the server read + dispatch,
/// then flush server->client.
fn roundtrip(client: *Client, client_fd: i32, msg: []const u8) !void {
    try writeAll(client_fd, msg);
    _ = client.conn.read() catch {};
    _ = client.drainMessages();
    try client.flush();
}

/// A decoded event header + body slice.
const Event = struct {
    object: u32,
    opcode: u16,
    body: []const u8,
};

/// Iterate wire events in a stream.
const EventIter = struct {
    stream: []const u8,
    off: usize = 0,

    fn next(self: *EventIter) ?Event {
        if (self.off + 8 > self.stream.len) return null;
        const obj = std.mem.readInt(u32, self.stream[self.off..][0..4], .little);
        const word1 = std.mem.readInt(u32, self.stream[self.off + 4 ..][0..4], .little);
        const size: u16 = @truncate(word1 >> 16);
        const opcode: u16 = @truncate(word1);
        if (size < 8 or self.off + size > self.stream.len) return null;
        const body = self.stream[self.off + 8 .. self.off + size];
        self.off += size;
        return .{ .object = obj, .opcode = opcode, .body = body };
    }
};

fn findGlobalName(stream: []const u8, registry_id: u32, want: []const u8) !u32 {
    var it = EventIter{ .stream = stream };
    while (it.next()) |ev| {
        if (ev.object == registry_id and ev.opcode == 0 and ev.body.len >= 8) {
            const name = std.mem.readInt(u32, ev.body[0..4], .little);
            const slen = std.mem.readInt(u32, ev.body[4..8], .little);
            if (slen >= 1 and 8 + slen - 1 <= ev.body.len) {
                const str = ev.body[8 .. 8 + slen - 1];
                if (std.mem.eql(u8, str, want)) return name;
            }
        }
    }
    return error.GlobalNotFound;
}

/// True if the stream carries a wl_display.error event (object 1, opcode 0).
fn hasProtocolError(stream: []const u8) bool {
    var it = EventIter{ .stream = stream };
    while (it.next()) |ev| {
        if (ev.object == wl.server_client.DISPLAY_ID and ev.opcode == 0) return true;
    }
    return false;
}

test "color-management: client negotiates PQ + Rec.2020 HDR end to end" {
    const gpa = std.testing.allocator;

    const d = try Display.create(gpa);

    // Stand up the wp_color_manager_v1 global with default HDR options (PQ +
    // Rec.2020 advertised, the parametric path enabled).
    const manager = try ColorManager.create(d, .{});
    // The display must be torn down BEFORE the manager: destroying client
    // resources runs the image-description destroy hooks, which reach back into
    // the still-live manager. Free the manager only afterwards.
    defer manager.deinit();
    defer d.destroy();

    const pair = try socketpair();
    const client_fd = pair[1];
    defer _ = linux.close(client_fd);
    const client = try Client.create(d, pair[0]);

    // Client-side id plan.
    const registry_id: u32 = 2;
    const manager_id: u32 = 3;
    const creator_id: u32 = 4;
    const image_desc_id: u32 = 5;
    const surface_id: u32 = 6; // a fabricated wl_surface
    const cm_surface_id: u32 = 7;

    // 1) get_registry, then bind wp_color_manager_v1.
    {
        const msg = try buildMessage(gpa, wl.server_client.DISPLAY_ID, 1, &.{registry_id});
        defer gpa.free(msg);
        try roundtrip(client, client_fd, msg);
    }
    var rbuf: [8192]u8 = undefined;
    const n_adv = readSome(client_fd, &rbuf);
    const manager_name = try findGlobalName(rbuf[0..n_adv], registry_id, "wp_color_manager_v1");

    {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);
        try writeU32(&body, gpa, manager_name);
        try appendString(&body, gpa, "wp_color_manager_v1");
        try writeU32(&body, gpa, cmp.WpColorManagerV1.version);
        try writeU32(&body, gpa, manager_id);
        const size: u32 = @intCast(8 + body.items.len);
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(gpa);
        try writeU32(&msg, gpa, registry_id);
        try writeU32(&msg, gpa, (size << 16) | 0);
        try msg.appendSlice(gpa, body.items);
        try roundtrip(client, client_fd, msg.items);
    }

    // Drain the supported_* advertisement and assert PQ + Rec.2020 + parametric.
    var ebuf: [8192]u8 = undefined;
    const n_ev = readSome(client_fd, &ebuf);
    var saw_pq = false;
    var saw_bt2020 = false;
    var saw_parametric = false;
    var saw_perceptual = false;
    var saw_done = false;
    {
        var it = EventIter{ .stream = ebuf[0..n_ev] };
        while (it.next()) |ev| {
            if (ev.object != manager_id) continue;
            switch (ev.opcode) {
                EV_SUPPORTED_INTENT => {
                    const v = std.mem.readInt(u32, ev.body[0..4], .little);
                    if (v == CMConst.RenderIntent.perceptual) saw_perceptual = true;
                },
                EV_SUPPORTED_FEATURE => {
                    const v = std.mem.readInt(u32, ev.body[0..4], .little);
                    if (v == CMConst.Feature.parametric) saw_parametric = true;
                },
                EV_SUPPORTED_TF_NAMED => {
                    const v = std.mem.readInt(u32, ev.body[0..4], .little);
                    if (v == CMConst.TransferFunction.st2084_pq) saw_pq = true;
                },
                EV_SUPPORTED_PRIMARIES_NAMED => {
                    const v = std.mem.readInt(u32, ev.body[0..4], .little);
                    if (v == CMConst.Primaries.bt2020) saw_bt2020 = true;
                },
                EV_DONE => saw_done = true,
                else => {},
            }
        }
    }
    try std.testing.expect(saw_pq); // PQ (st2084) advertised
    try std.testing.expect(saw_bt2020); // Rec.2020 advertised
    try std.testing.expect(saw_parametric);
    try std.testing.expect(saw_perceptual);
    try std.testing.expect(saw_done);

    // 2) create_parametric_creator(creator_id).
    {
        const msg = try buildMessage(gpa, manager_id, REQ_CREATE_PARAMETRIC_CREATOR, &.{creator_id});
        defer gpa.free(msg);
        try roundtrip(client, client_fd, msg);
    }
    try std.testing.expect(client.getObject(creator_id) != null);

    // set_tf_named(st2084_pq).
    {
        const msg = try buildMessage(gpa, creator_id, PARAMS_SET_TF_NAMED, &.{CMConst.TransferFunction.st2084_pq});
        defer gpa.free(msg);
        try roundtrip(client, client_fd, msg);
    }
    // set_primaries_named(bt2020).
    {
        const msg = try buildMessage(gpa, creator_id, PARAMS_SET_PRIMARIES_NAMED, &.{CMConst.Primaries.bt2020});
        defer gpa.free(msg);
        try roundtrip(client, client_fd, msg);
    }
    // set_mastering_luminance(min 0.005*10000 = 50, max 1000 nits).
    {
        const msg = try buildMessage(gpa, creator_id, PARAMS_SET_MASTERING_LUMINANCE, &.{ 50, 1000 });
        defer gpa.free(msg);
        try roundtrip(client, client_fd, msg);
    }
    // create(image_desc_id) -> the description should post ready2.
    {
        const msg = try buildMessage(gpa, creator_id, PARAMS_CREATE, &.{image_desc_id});
        defer gpa.free(msg);
        try roundtrip(client, client_fd, msg);
    }

    // Read the image-description events: assert ready2 (v2) and no failed/error.
    var dbuf: [4096]u8 = undefined;
    const n_d = readSome(client_fd, &dbuf);
    try std.testing.expect(!hasProtocolError(dbuf[0..n_d]));
    var saw_ready = false;
    var saw_failed = false;
    {
        var it = EventIter{ .stream = dbuf[0..n_d] };
        while (it.next()) |ev| {
            if (ev.object != image_desc_id) continue;
            if (ev.opcode == IMG_EV_READY2 or ev.opcode == IMG_EV_READY) saw_ready = true;
            if (ev.opcode == IMG_EV_FAILED) saw_failed = true;
        }
    }
    try std.testing.expect(saw_ready);
    try std.testing.expect(!saw_failed);
    // The creator resource was destroyed by create().
    try std.testing.expect(client.getObject(creator_id) == null);
    // The image description resource exists and holds the parametric record.
    try std.testing.expect(client.getObject(image_desc_id) != null);

    // 3) Fabricate a wl_surface server-side, then get_surface + set the desc.
    const surface = try Object.create(client, &wlp.WlSurface.interface, 4, surface_id);
    _ = surface;
    {
        const msg = try buildMessage(gpa, manager_id, REQ_GET_SURFACE, &.{ cm_surface_id, surface_id });
        defer gpa.free(msg);
        try roundtrip(client, client_fd, msg);
    }
    try std.testing.expect(client.getObject(cm_surface_id) != null);

    // set_image_description(image_desc, perceptual). object + uint body.
    {
        const msg = try buildMessage(gpa, cm_surface_id, SURFACE_SET_IMAGE_DESCRIPTION, &.{ image_desc_id, CMConst.RenderIntent.perceptual });
        defer gpa.free(msg);
        try roundtrip(client, client_fd, msg);
    }

    // No protocol error must have been raised by any of the above.
    var fbuf: [1024]u8 = undefined;
    const n_f = readSome(client_fd, &fbuf);
    try std.testing.expect(!hasProtocolError(fbuf[0..n_f]));

    // The server stored the per-surface HDR state: PQ + Rec.2020 + perceptual.
    const state = manager.surfaceState(surface_id) orelse return error.NoSurfaceState;
    try std.testing.expectEqual(CMConst.RenderIntent.perceptual, state.render_intent);
    try std.testing.expectEqual(@as(?u32, CMConst.TransferFunction.st2084_pq), state.description.tf_named);
    try std.testing.expectEqual(@as(?u32, CMConst.Primaries.bt2020), state.description.primaries_named);
    try std.testing.expectEqual(@as(?u32, 50), state.description.mastering_min_lum);
    try std.testing.expectEqual(@as(?u32, 1000), state.description.mastering_max_lum);
}

test "color-management: invalid render intent raises a protocol error" {
    const gpa = std.testing.allocator;
    const d = try Display.create(gpa);
    const manager = try ColorManager.create(d, .{});
    defer manager.deinit();
    defer d.destroy();

    const pair = try socketpair();
    const client_fd = pair[1];
    defer _ = linux.close(client_fd);
    const client = try Client.create(d, pair[0]);

    const registry_id: u32 = 2;
    const manager_id: u32 = 3;
    const creator_id: u32 = 4;
    const image_desc_id: u32 = 5;
    const surface_id: u32 = 6;
    const cm_surface_id: u32 = 7;

    // Bind.
    {
        const msg = try buildMessage(gpa, wl.server_client.DISPLAY_ID, 1, &.{registry_id});
        defer gpa.free(msg);
        try roundtrip(client, client_fd, msg);
    }
    var rbuf: [8192]u8 = undefined;
    const n_adv = readSome(client_fd, &rbuf);
    const manager_name = try findGlobalName(rbuf[0..n_adv], registry_id, "wp_color_manager_v1");
    {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);
        try writeU32(&body, gpa, manager_name);
        try appendString(&body, gpa, "wp_color_manager_v1");
        try writeU32(&body, gpa, cmp.WpColorManagerV1.version);
        try writeU32(&body, gpa, manager_id);
        const size: u32 = @intCast(8 + body.items.len);
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(gpa);
        try writeU32(&msg, gpa, registry_id);
        try writeU32(&msg, gpa, (size << 16) | 0);
        try msg.appendSlice(gpa, body.items);
        try roundtrip(client, client_fd, msg.items);
    }
    var skip: [8192]u8 = undefined;
    _ = readSome(client_fd, &skip);

    // Build a ready PQ+Rec.2020 description.
    {
        const m1 = try buildMessage(gpa, manager_id, REQ_CREATE_PARAMETRIC_CREATOR, &.{creator_id});
        defer gpa.free(m1);
        try roundtrip(client, client_fd, m1);
        const m2 = try buildMessage(gpa, creator_id, PARAMS_SET_TF_NAMED, &.{CMConst.TransferFunction.st2084_pq});
        defer gpa.free(m2);
        try roundtrip(client, client_fd, m2);
        const m3 = try buildMessage(gpa, creator_id, PARAMS_SET_PRIMARIES_NAMED, &.{CMConst.Primaries.bt2020});
        defer gpa.free(m3);
        try roundtrip(client, client_fd, m3);
        const m4 = try buildMessage(gpa, creator_id, PARAMS_CREATE, &.{image_desc_id});
        defer gpa.free(m4);
        try roundtrip(client, client_fd, m4);
    }
    _ = readSome(client_fd, &skip);

    // get_surface, then set_image_description with an UNADVERTISED render intent
    // value (99) -> render_intent protocol error.
    _ = try Object.create(client, &wlp.WlSurface.interface, 4, surface_id);
    {
        const m = try buildMessage(gpa, manager_id, REQ_GET_SURFACE, &.{ cm_surface_id, surface_id });
        defer gpa.free(m);
        try roundtrip(client, client_fd, m);
    }
    {
        const m = try buildMessage(gpa, cm_surface_id, SURFACE_SET_IMAGE_DESCRIPTION, &.{ image_desc_id, 99 });
        defer gpa.free(m);
        try roundtrip(client, client_fd, m);
    }
    var ebuf: [1024]u8 = undefined;
    const n_e = readSome(client_fd, &ebuf);
    try std.testing.expect(hasProtocolError(ebuf[0..n_e]));
    // No surface state should have been stored.
    try std.testing.expect(manager.surfaceState(surface_id) == null);
}
