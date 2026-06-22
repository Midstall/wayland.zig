//! wayland-info: a Wayland client that enumerates a running server's globals
//! and prints their details, the Zig reimplementation of wayland-utils'
//! `wayland-info`.
//!
//! It exercises this library's client side (src/wayland/client.zig + the
//! generated client bindings), the counterpart to how the example server
//! exercises the server side. No protocol is baked into the runtime: the
//! wayland.xml bindings are generated and imported here as `wlp`.
//!
//! Flow (mirrors the real wayland-info):
//!   1. connect to $WAYLAND_DISPLAY (absolute, else under $XDG_RUNTIME_DIR;
//!      default wayland-0).
//!   2. wl_display.get_registry, then wl_display.sync; pump events until the
//!      sync wl_callback.done fires - that marks the end of the initial global
//!      burst (a roundtrip). Every wl_registry.global is collected.
//!   3. bind wl_shm / wl_output / wl_seat, then a second wl_display.sync; pump
//!      events until its done fires, decoding each interface's detail events
//!      (shm.format, output.geometry/mode/scale/name/done, seat.capabilities/
//!      name) against the generated interface signatures via argument.demarshal.
//!   4. print the globals + details and exit 0.
//!
//! `wl` is the abstract runtime, `wlp` the generated wayland.xml bindings.

const std = @import("std");

const wl = @import("wayland");
const wlp = @import("wayland_protocol");
const cmp = @import("color_management_protocol");

const client = wl.client;
const Argument = wl.Argument;

// wl_registry object id is always allocated first by get_registry; the well
// known wl_display id is 1.
const WL_DISPLAY_ID: u32 = 1;

// A collected global from the registry burst.
const Global = struct {
    name: u32,
    interface: []u8, // owned copy (the wire buffer is reused per message)
    version: u32,
};

// Per-output accumulated detail (a wl_output emits a burst terminated by done).
const OutputInfo = struct {
    object_id: u32,
    global_name: u32,
    has_geometry: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    phys_w: i32 = 0,
    phys_h: i32 = 0,
    subpixel: i32 = 0,
    make: [64]u8 = undefined,
    make_len: usize = 0,
    model: [64]u8 = undefined,
    model_len: usize = 0,
    transform: i32 = 0,
    has_mode: bool = false,
    mode_flags: u32 = 0,
    mode_w: i32 = 0,
    mode_h: i32 = 0,
    mode_refresh: i32 = 0,
    scale: i32 = 1,
    name: [64]u8 = undefined,
    name_len: usize = 0,
    desc: [128]u8 = undefined,
    desc_len: usize = 0,
};

const SeatInfo = struct {
    object_id: u32,
    global_name: u32,
    caps: u32 = 0,
    name: [64]u8 = undefined,
    name_len: usize = 0,
};

// State shared across the two roundtrips.
const Enumerator = struct {
    allocator: std.mem.Allocator,
    conn: *client.Connection,
    imap: *client.InterfaceMap,
    registry_id: u32,

    globals: std.ArrayList(Global) = .empty,

    // shm formats (DRM fourcc codes) collected from wl_shm.format.
    shm_object_id: u32 = 0,
    shm_global_name: u32 = 0,
    shm_formats: std.ArrayList(u32) = .empty,

    outputs: std.ArrayList(OutputInfo) = .empty,
    seats: std.ArrayList(SeatInfo) = .empty,

    // wp_color_manager_v1 HDR capabilities (the supported_* burst).
    cm_object_id: u32 = 0,
    cm_global_name: u32 = 0,
    cm_intents: std.ArrayList(u32) = .empty,
    cm_features: std.ArrayList(u32) = .empty,
    cm_tfs: std.ArrayList(u32) = .empty,
    cm_primaries: std.ArrayList(u32) = .empty,

    // The id of the in-flight wl_callback created by a sync; its done event
    // ends the current roundtrip.
    sync_callback_id: u32 = 0,
    sync_done: bool = false,

    fn deinit(self: *Enumerator) void {
        for (self.globals.items) |g| self.allocator.free(g.interface);
        self.globals.deinit(self.allocator);
        self.shm_formats.deinit(self.allocator);
        self.outputs.deinit(self.allocator);
        self.seats.deinit(self.allocator);
        self.cm_intents.deinit(self.allocator);
        self.cm_features.deinit(self.allocator);
        self.cm_tfs.deinit(self.allocator);
        self.cm_primaries.deinit(self.allocator);
    }

    fn findOutput(self: *Enumerator, id: u32) ?*OutputInfo {
        for (self.outputs.items) |*o| if (o.object_id == id) return o;
        return null;
    }
    fn findSeat(self: *Enumerator, id: u32) ?*SeatInfo {
        for (self.seats.items) |*s| if (s.object_id == id) return s;
        return null;
    }

    /// Issue wl_display.sync and pump events until the returned callback's done
    /// fires. This is the roundtrip: the server handles every prior request and
    /// emits the resulting events in order before the sync's done.
    fn roundtrip(self: *Enumerator) !void {
        self.sync_callback_id = try client.sync(self.conn);
        // The callback is a wl_callback: record its interface so its done event
        // routes correctly.
        try self.imap.set(self.sync_callback_id, &wlp.WlCallback.interface);
        self.sync_done = false;

        var msg_buf: [4096]u8 = undefined;
        var args: [16]Argument = undefined;
        while (!self.sync_done) {
            const ev = (try client.dispatchEvent(self.conn, self.imap, &msg_buf, &args)) orelse continue;
            try self.handleEvent(ev);
        }
    }

    fn handleEvent(self: *Enumerator, ev: client.DecodedEvent) !void {
        const iface = ev.interface;
        // wl_callback.done ends the roundtrip.
        if (iface == &wlp.WlCallback.interface and ev.object_id == self.sync_callback_id) {
            if (ev.opcode == @intFromEnum(wlp.WlCallback.EventOpcode.done)) {
                self.sync_done = true;
                self.imap.remove(self.sync_callback_id);
            }
            return;
        }
        // wl_display events (error / delete_id).
        if (iface == &wlp.WlDisplay.interface) {
            if (ev.opcode == @intFromEnum(wlp.WlDisplay.EventOpcode.@"error")) {
                std.debug.print("server error on object {d}: code {d}: {s}\n", .{
                    ev.args[0].object orelse 0, ev.args[1].uint, ev.args[2].string orelse "",
                });
                return error.ServerError;
            }
            return; // delete_id: nothing to track here
        }
        // wl_registry.global / global_remove.
        if (iface == &wlp.WlRegistry.interface) {
            if (ev.opcode == @intFromEnum(wlp.WlRegistry.EventOpcode.global)) {
                const name = ev.args[0].uint;
                const ifc = ev.args[1].string orelse return;
                const ver = ev.args[2].uint;
                const owned = try self.allocator.dupe(u8, ifc);
                try self.globals.append(self.allocator, .{ .name = name, .interface = owned, .version = ver });
            }
            return;
        }
        // wl_shm.format.
        if (iface == &wlp.WlShm.interface) {
            if (ev.opcode == @intFromEnum(wlp.WlShm.EventOpcode.format)) {
                try self.shm_formats.append(self.allocator, ev.args[0].uint);
            }
            return;
        }
        // wl_output detail burst.
        if (iface == &wlp.WlOutput.interface) {
            const out = self.findOutput(ev.object_id) orelse return;
            try handleOutputEvent(out, ev);
            return;
        }
        // wp_color_manager_v1 supported_* HDR advertisement burst.
        if (iface == &cmp.WpColorManagerV1.interface) {
            switch (@as(cmp.WpColorManagerV1.EventOpcode, @enumFromInt(ev.opcode))) {
                .supported_intent => try self.cm_intents.append(self.allocator, ev.args[0].uint),
                .supported_feature => try self.cm_features.append(self.allocator, ev.args[0].uint),
                .supported_tf_named => try self.cm_tfs.append(self.allocator, ev.args[0].uint),
                .supported_primaries_named => try self.cm_primaries.append(self.allocator, ev.args[0].uint),
                .done => {},
            }
            return;
        }
        // wl_seat capabilities / name.
        if (iface == &wlp.WlSeat.interface) {
            const seat = self.findSeat(ev.object_id) orelse return;
            switch (@as(wlp.WlSeat.EventOpcode, @enumFromInt(ev.opcode))) {
                .capabilities => seat.caps = ev.args[0].uint,
                .name => {
                    const s = ev.args[0].string orelse "";
                    const n = @min(s.len, seat.name.len);
                    @memcpy(seat.name[0..n], s[0..n]);
                    seat.name_len = n;
                },
            }
            return;
        }
    }
};

fn handleOutputEvent(out: *OutputInfo, ev: client.DecodedEvent) !void {
    switch (@as(wlp.WlOutput.EventOpcode, @enumFromInt(ev.opcode))) {
        .geometry => {
            out.has_geometry = true;
            out.x = ev.args[0].int;
            out.y = ev.args[1].int;
            out.phys_w = ev.args[2].int;
            out.phys_h = ev.args[3].int;
            out.subpixel = ev.args[4].int;
            const mk = ev.args[5].string orelse "";
            out.make_len = @min(mk.len, out.make.len);
            @memcpy(out.make[0..out.make_len], mk[0..out.make_len]);
            const md = ev.args[6].string orelse "";
            out.model_len = @min(md.len, out.model.len);
            @memcpy(out.model[0..out.model_len], md[0..out.model_len]);
            out.transform = ev.args[7].int;
        },
        .mode => {
            out.has_mode = true;
            out.mode_flags = ev.args[0].uint;
            out.mode_w = ev.args[1].int;
            out.mode_h = ev.args[2].int;
            out.mode_refresh = ev.args[3].int;
        },
        .scale => out.scale = ev.args[0].int,
        .name => {
            const s = ev.args[0].string orelse "";
            out.name_len = @min(s.len, out.name.len);
            @memcpy(out.name[0..out.name_len], s[0..out.name_len]);
        },
        .description => {
            const s = ev.args[0].string orelse "";
            out.desc_len = @min(s.len, out.desc.len);
            @memcpy(out.desc[0..out.desc_len], s[0..out.desc_len]);
        },
        .done => {}, // burst end: nothing more to accumulate
    }
}

const subpixel_names = [_][]const u8{ "unknown", "none", "horizontal rgb", "horizontal bgr", "vertical rgb", "vertical bgr" };
const transform_names = [_][]const u8{ "normal", "90", "180", "270", "flipped", "flipped 90", "flipped 180", "flipped 270" };

/// Render a wl_shm DRM format code as its 4-character fourcc, as wayland-info
/// does (argb8888 -> 'AR24', xrgb8888 -> 'XR24'). The two well-known codes 0
/// and 1 are not ascii fourccs; map them to their canonical drm_fourcc names.
fn formatFourcc(code: u32, buf: *[6]u8) []const u8 {
    switch (code) {
        0 => return "AR24", // argb8888 (DRM_FORMAT_ARGB8888)
        1 => return "XR24", // xrgb8888 (DRM_FORMAT_XRGB8888)
        else => {},
    }
    // Other codes already ARE little-endian fourcc ascii.
    buf[0] = '\'';
    buf[1] = @truncate(code & 0xff);
    buf[2] = @truncate((code >> 8) & 0xff);
    buf[3] = @truncate((code >> 16) & 0xff);
    buf[4] = @truncate((code >> 24) & 0xff);
    buf[5] = '\'';
    return buf[0..6];
}

fn formatName(code: u32) []const u8 {
    return switch (code) {
        0 => "argb8888",
        1 => "xrgb8888",
        else => "",
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &w.interface;

    var stderr_buf: [512]u8 = undefined;
    var ew = std.Io.File.stderr().writer(io, &stderr_buf);
    const err = &ew.interface;

    // Resolve the socket path from the environment map (libc-free: no getenv).
    var path_buf: [4096]u8 = undefined;
    const socket_path = client.resolveSocketPath(init.environ_map, &path_buf) catch |e| {
        try err.print("wayland-info: cannot determine the Wayland socket: {s}\n", .{@errorName(e)});
        try err.flush();
        std.process.exit(1);
    };

    var conn = client.connect(gpa, io, socket_path) catch |e| {
        try err.print("wayland-info: failed to connect to '{s}': {s}\n", .{ socket_path, @errorName(e) });
        try err.flush();
        std.process.exit(1);
    };
    defer conn.deinit();

    var imap = client.InterfaceMap.init(gpa);
    defer imap.deinit();
    // wl_display is object 1.
    try imap.set(WL_DISPLAY_ID, &wlp.WlDisplay.interface);

    // get_registry; record the new registry id as a wl_registry.
    const registry_id = try client.getRegistry(&conn);
    try imap.set(registry_id, &wlp.WlRegistry.interface);

    var enumr = Enumerator{
        .allocator = gpa,
        .conn = &conn,
        .imap = &imap,
        .registry_id = registry_id,
    };
    defer enumr.deinit();

    // Roundtrip 1: drain the initial global burst.
    enumr.roundtrip() catch |e| {
        try err.print("wayland-info: registry roundtrip failed: {s}\n", .{@errorName(e)});
        try err.flush();
        std.process.exit(1);
    };

    // Bind the common interfaces so their detail events arrive in roundtrip 2.
    for (enumr.globals.items) |g| {
        if (std.mem.eql(u8, g.interface, "wl_shm")) {
            const ver = @min(g.version, wlp.WlShm.version);
            const id = try client.bindGlobal(&conn, registry_id, g.name, "wl_shm", ver);
            try imap.set(id, &wlp.WlShm.interface);
            enumr.shm_object_id = id;
            enumr.shm_global_name = g.name;
        } else if (std.mem.eql(u8, g.interface, "wl_output")) {
            const ver = @min(g.version, wlp.WlOutput.version);
            const id = try client.bindGlobal(&conn, registry_id, g.name, "wl_output", ver);
            try imap.set(id, &wlp.WlOutput.interface);
            try enumr.outputs.append(gpa, .{ .object_id = id, .global_name = g.name });
        } else if (std.mem.eql(u8, g.interface, "wl_seat")) {
            const ver = @min(g.version, wlp.WlSeat.version);
            const id = try client.bindGlobal(&conn, registry_id, g.name, "wl_seat", ver);
            try imap.set(id, &wlp.WlSeat.interface);
            try enumr.seats.append(gpa, .{ .object_id = id, .global_name = g.name });
        } else if (std.mem.eql(u8, g.interface, "wp_color_manager_v1")) {
            // Binding immediately triggers the supported_* HDR burst, drained in
            // roundtrip 2.
            const ver = @min(g.version, cmp.WpColorManagerV1.version);
            const id = try client.bindGlobal(&conn, registry_id, g.name, "wp_color_manager_v1", ver);
            try imap.set(id, &cmp.WpColorManagerV1.interface);
            enumr.cm_object_id = id;
            enumr.cm_global_name = g.name;
        }
    }

    // Roundtrip 2: drain the detail events from the binds above.
    enumr.roundtrip() catch |e| {
        try err.print("wayland-info: detail roundtrip failed: {s}\n", .{@errorName(e)});
        try err.flush();
        std.process.exit(1);
    };

    try printReport(out, &enumr);
    try out.flush();
    std.process.exit(0);
}

fn printReport(out: anytype, enumr: *Enumerator) !void {
    for (enumr.globals.items) |g| {
        try out.print("interface: '{s}', version: {d}, name: {d}\n", .{ g.interface, g.version, g.name });

        if (std.mem.eql(u8, g.interface, "wl_shm")) {
            try out.writeAll("\tformats (fourcc):\n");
            for (enumr.shm_formats.items) |code| {
                var fbuf: [6]u8 = undefined;
                const fcc = formatFourcc(code, &fbuf);
                const nm = formatName(code);
                if (nm.len > 0) {
                    try out.print("\t\t{s} ({s})\n", .{ fcc, nm });
                } else {
                    try out.print("\t\t{s}\n", .{fcc});
                }
            }
        } else if (std.mem.eql(u8, g.interface, "wl_output")) {
            if (findOutputByGlobal(enumr, g.name)) |o| try printOutput(out, o);
        } else if (std.mem.eql(u8, g.interface, "wl_seat")) {
            if (findSeatByGlobal(enumr, g.name)) |s| try printSeat(out, s);
        } else if (std.mem.eql(u8, g.interface, "wp_color_manager_v1")) {
            try printColorManager(out, enumr);
        }
    }
}

/// Print the wp_color_manager_v1 HDR capabilities a compositor advertises:
/// supported rendering intents, features, named transfer functions, and named
/// primaries. The HDR-relevant names (st2084_pq, hlg, bt2020) are labeled.
fn printColorManager(out: anytype, enumr: *Enumerator) !void {
    try out.writeAll("\tsupported rendering intents:");
    for (enumr.cm_intents.items) |v| try out.print(" {s}", .{intentName(v)});
    try out.writeAll("\n\tsupported features:");
    for (enumr.cm_features.items) |v| try out.print(" {s}", .{featureName(v)});
    try out.writeAll("\n\tsupported transfer functions:");
    for (enumr.cm_tfs.items) |v| try out.print(" {s}", .{tfName(v)});
    try out.writeAll("\n\tsupported primaries:");
    for (enumr.cm_primaries.items) |v| try out.print(" {s}", .{primariesName(v)});
    try out.writeAll("\n");
}

fn intentName(v: u32) []const u8 {
    return switch (v) {
        0 => "perceptual",
        1 => "relative",
        2 => "saturation",
        3 => "absolute",
        4 => "relative_bpc",
        5 => "absolute_no_adaptation",
        else => "?",
    };
}

fn featureName(v: u32) []const u8 {
    return switch (v) {
        0 => "icc_v2_v4",
        1 => "parametric",
        2 => "set_primaries",
        3 => "set_tf_power",
        4 => "set_luminances",
        5 => "set_mastering_display_primaries",
        6 => "extended_target_volume",
        7 => "windows_scrgb",
        else => "?",
    };
}

fn tfName(v: u32) []const u8 {
    return switch (v) {
        1 => "bt1886",
        2 => "gamma22",
        3 => "gamma28",
        4 => "st240",
        5 => "ext_linear",
        6 => "log_100",
        7 => "log_316",
        8 => "xvycc",
        9 => "srgb",
        10 => "ext_srgb",
        11 => "st2084_pq",
        12 => "st428",
        13 => "hlg",
        14 => "compound_power_2_4",
        else => "?",
    };
}

fn primariesName(v: u32) []const u8 {
    return switch (v) {
        1 => "srgb",
        2 => "pal_m",
        3 => "pal",
        4 => "ntsc",
        5 => "generic_film",
        6 => "bt2020",
        7 => "cie1931_xyz",
        8 => "dci_p3",
        9 => "display_p3",
        10 => "adobe_rgb",
        else => "?",
    };
}

fn findOutputByGlobal(enumr: *Enumerator, name: u32) ?*OutputInfo {
    for (enumr.outputs.items) |*o| if (o.global_name == name) return o;
    return null;
}
fn findSeatByGlobal(enumr: *Enumerator, name: u32) ?*SeatInfo {
    for (enumr.seats.items) |*s| if (s.global_name == name) return s;
    return null;
}

fn printOutput(out: anytype, o: *OutputInfo) !void {
    if (o.name_len > 0) try out.print("\tname: {s}\n", .{o.name[0..o.name_len]});
    if (o.desc_len > 0) try out.print("\tdescription: {s}\n", .{o.desc[0..o.desc_len]});
    if (o.has_geometry) {
        const sp: []const u8 = if (o.subpixel >= 0 and o.subpixel < subpixel_names.len)
            subpixel_names[@intCast(o.subpixel)]
        else
            "unknown";
        const tr: []const u8 = if (o.transform >= 0 and o.transform < transform_names.len)
            transform_names[@intCast(o.transform)]
        else
            "unknown";
        try out.print("\tx: {d}, y: {d}\n", .{ o.x, o.y });
        try out.print("\tphysical_width: {d} mm, physical_height: {d} mm\n", .{ o.phys_w, o.phys_h });
        try out.print("\tmake: '{s}', model: '{s}'\n", .{ o.make[0..o.make_len], o.model[0..o.model_len] });
        try out.print("\tsubpixel: {s}\n", .{sp});
        try out.print("\ttransform: {s}\n", .{tr});
    }
    if (o.has_mode) {
        try out.print("\tmode:\n", .{});
        // refresh comes in mHz; print Hz with three decimals like wayland-info.
        const hz_whole = @divTrunc(o.mode_refresh, 1000);
        const hz_frac: u32 = @intCast(@mod(o.mode_refresh, 1000));
        const cur = (o.mode_flags & wlp.WlOutput.Mode.current) != 0;
        const pref = (o.mode_flags & wlp.WlOutput.Mode.preferred) != 0;
        var frac_buf: [3]u8 = .{ '0', '0', '0' };
        frac_buf[0] = '0' + @as(u8, @intCast((hz_frac / 100) % 10));
        frac_buf[1] = '0' + @as(u8, @intCast((hz_frac / 10) % 10));
        frac_buf[2] = '0' + @as(u8, @intCast(hz_frac % 10));
        try out.print("\t\twidth: {d} px, height: {d} px, refresh: {d}.{s} Hz\n", .{ o.mode_w, o.mode_h, hz_whole, &frac_buf });
        try out.print("\t\tflags:{s}{s}\n", .{
            if (cur) " current" else "",
            if (pref) " preferred" else "",
        });
    }
    try out.print("\tscale: {d}\n", .{o.scale});
}

fn printSeat(out: anytype, s: *SeatInfo) !void {
    if (s.name_len > 0) try out.print("\tname: {s}\n", .{s.name[0..s.name_len]});
    try out.writeAll("\tcapabilities:");
    if (s.caps & wlp.WlSeat.Capability.pointer != 0) try out.writeAll(" pointer");
    if (s.caps & wlp.WlSeat.Capability.keyboard != 0) try out.writeAll(" keyboard");
    if (s.caps & wlp.WlSeat.Capability.touch != 0) try out.writeAll(" touch");
    try out.writeAll("\n");
}
