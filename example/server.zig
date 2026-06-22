//! Example Wayland server: the libwayland-server equivalent in action.
//!
//! A bare server skeleton a compositor would fill with its own policy. It
//! stands up a Display on an auto-picked socket and registers the core globals
//! a client expects to find, using the generated wayland.xml server stubs:
//!
//!   wl_compositor - create_surface / create_region make child resources
//!   wl_shm        - the reusable Shm helper (advertises argb8888 + xrgb8888)
//!   wl_output     - on bind: geometry + mode (1920x1080) + scale + name + done
//!   wl_seat       - on bind: capabilities (pointer|keyboard) + name
//!
//! It prints the chosen socket name to stdout (so a harness can connect), then
//! runs the event loop until the first client disconnects, or SIGINT/SIGTERM,
//! or a watchdog fires. Exits 0.
//!
//! `wl` is the abstract runtime; `wlp` is the generated wayland.xml bindings.

const std = @import("std");
const linux = std.os.linux;

const wl = @import("wayland");
const wlp = @import("wayland_protocol");
const cmp = @import("color_management_protocol");

const Display = wl.Display;
const Client = wl.server_client.Client;
const Object = wl.Object;
const Listener = wl.Listener;
const Shm = wl.shm.Shm(wlp);
const ColorManager = @import("color_management.zig").ColorManager(cmp);

// The mode flags from wl_output: current(0x1) | preferred(0x2).
const OUTPUT_MODE_CURRENT: u32 = 0x1;
const OUTPUT_MODE_PREFERRED: u32 = 0x2;
// wl_seat capabilities: pointer(1) | keyboard(2).
const SEAT_CAP_POINTER: u32 = 1;
const SEAT_CAP_KEYBOARD: u32 = 2;

/// Shared server state. Held alive for the program's run; bind callbacks reach
/// it via the global's user_data.
const Server = struct {
    display: *Display,
    compositor_impl: wlp.WlCompositor.Implementation,
    surface_impl: wlp.WlSurface.Implementation,
    region_impl: wlp.WlRegion.Implementation,
    first_client_listener: Listener,
    client_destroy_listener: Listener,
    saw_client: bool = false,
};

fn bindCompositor(client: *Client, data: ?*anyopaque, version: u32, id: u32) void {
    const server: *Server = @ptrCast(@alignCast(data.?));
    const resource = Object.create(client, &wlp.WlCompositor.interface, version, id) catch return;
    wlp.WlCompositor.setImplementation(resource, &server.compositor_impl, server, null);
}

fn onCreateSurface(client_data: ?*anyopaque, resource: *Object, id: u32) void {
    const server: *Server = @ptrCast(@alignCast(client_data.?));
    const surface = Object.create(resource.client, &wlp.WlSurface.interface, resource.version, id) catch return;
    wlp.WlSurface.setImplementation(surface, &server.surface_impl, server, null);
}

fn onCreateRegion(client_data: ?*anyopaque, resource: *Object, id: u32) void {
    const server: *Server = @ptrCast(@alignCast(client_data.?));
    const region = Object.create(resource.client, &wlp.WlRegion.interface, resource.version, id) catch return;
    wlp.WlRegion.setImplementation(region, &server.region_impl, server, null);
}

fn bindOutput(client: *Client, data: ?*anyopaque, version: u32, id: u32) void {
    _ = data;
    const resource = Object.create(client, &wlp.WlOutput.interface, version, id) catch return;
    // geometry(x, y, phys_w_mm, phys_h_mm, subpixel, make, model, transform)
    wlp.WlOutput.sendGeometry(resource, 0, 0, 510, 287, 0, "wayland-zig", "Virtual-1", 0);
    // mode(flags, width, height, refresh_mHz): the current+preferred 1920x1080@60.
    wlp.WlOutput.sendMode(resource, OUTPUT_MODE_CURRENT | OUTPUT_MODE_PREFERRED, 1920, 1080, 60000);
    // scale (since v2) and name (since v4) only when the bound version allows.
    if (version >= 2) wlp.WlOutput.sendScale(resource, 1);
    if (version >= 4) wlp.WlOutput.sendName(resource, "WL-1");
    if (version >= 2) wlp.WlOutput.sendDone(resource);
}

fn bindSeat(client: *Client, data: ?*anyopaque, version: u32, id: u32) void {
    _ = data;
    const resource = Object.create(client, &wlp.WlSeat.interface, version, id) catch return;
    wlp.WlSeat.sendCapabilities(resource, SEAT_CAP_POINTER | SEAT_CAP_KEYBOARD);
    // name (since v2).
    if (version >= 2) wlp.WlSeat.sendName(resource, "seat0");
}

fn onClientCreated(listener: *Listener, data: ?*anyopaque) void {
    const server: *Server = @fieldParentPtr("first_client_listener", listener);
    const client: *Client = @ptrCast(@alignCast(data.?));
    if (server.saw_client) return;
    server.saw_client = true;
    // Hook this client's destroy so we terminate when it disconnects.
    server.client_destroy_listener.notify = onClientDestroyed;
    client.destroy_signal.add(&server.client_destroy_listener);
}

fn onClientDestroyed(listener: *Listener, data: ?*anyopaque) void {
    _ = data;
    const server: *Server = @fieldParentPtr("client_destroy_listener", listener);
    server.display.terminate();
}

var g_display: ?*Display = null;

fn onSignal(signum: i32, data: ?*anyopaque) callconv(.c) c_int {
    _ = signum;
    _ = data;
    if (g_display) |d| d.terminate();
    return 1;
}

fn onWatchdog(data: ?*anyopaque) callconv(.c) c_int {
    _ = data;
    if (g_display) |d| d.terminate();
    return 1;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [1024]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &w.interface;

    const display = try Display.create(gpa);
    errdefer display.destroy();
    g_display = display;

    var server = Server{
        .display = display,
        .compositor_impl = .{ .create_surface = onCreateSurface, .create_region = onCreateRegion },
        .surface_impl = .{},
        .region_impl = .{},
        .first_client_listener = .{ .link = undefined, .notify = onClientCreated },
        .client_destroy_listener = .{ .link = undefined, .notify = onClientDestroyed },
    };

    // wl_compositor at version 4 (the example's surface/region requests exist
    // at that level), wl_output v4, wl_seat v9 (so name events are valid).
    _ = try display.globalCreate(&wlp.WlCompositor.interface, 4, bindCompositor, &server);
    const shm = try Shm.create(display);
    errdefer shm.deinit();
    _ = try display.globalCreate(&wlp.WlOutput.interface, wlp.WlOutput.version, bindOutput, &server);
    _ = try display.globalCreate(&wlp.WlSeat.interface, wlp.WlSeat.version, bindSeat, &server);

    // wp_color_manager_v1: advertise HDR (PQ + Rec.2020 + the parametric path)
    // and report a PQ/Rec.2020 HDR output description. This is the signaling a
    // compositor uses to negotiate HDR with its clients.
    const cm = try ColorManager.create(display, .{});
    errdefer cm.deinit();

    // Terminate when the first client disconnects.
    display.client_created_signal.add(&server.first_client_listener);

    const loop = display.getEventLoop();

    // SIGINT / SIGTERM -> clean terminate. (SIGINT=2, SIGTERM=15.)
    const sigint_src = loop.addSignal(2, onSignal, null) catch null;
    errdefer if (sigint_src) |s| loop.eventSourceRemove(s);
    const sigterm_src = loop.addSignal(15, onSignal, null) catch null;
    errdefer if (sigterm_src) |s| loop.eventSourceRemove(s);

    // A watchdog so an unattended run can never hang forever (30s).
    const watchdog = try loop.addTimer(onWatchdog, null);
    errdefer loop.eventSourceRemove(watchdog);
    try loop.timerUpdate(watchdog, 30_000);

    // Pick a socket and tell the harness which one. The runtime dir comes from
    // XDG_RUNTIME_DIR via the process environment map (std.posix.getenv is not
    // available in a libc-free executable, so we read it explicitly).
    const runtime_dir = init.environ_map.get("XDG_RUNTIME_DIR") orelse {
        try out.writeAll("error: XDG_RUNTIME_DIR is not set\n");
        try out.flush();
        std.process.exit(1);
    };
    var name_buf: [16]u8 = undefined;
    const name = try display.addSocketAutoInDir(runtime_dir, &name_buf);
    try out.print("WAYLAND_DISPLAY={s}\n", .{name});
    try out.flush();

    display.run();

    // Teardown order matters: destroy the display first so it reaps any
    // still-connected client and fires the helpers' resource destroy hooks
    // while their state is alive, then free the helpers. Removing the event
    // sources hands them to the loop's destroy list, which display.destroy()
    // frees as it tears the loop down.
    if (sigint_src) |s| loop.eventSourceRemove(s);
    if (sigterm_src) |s| loop.eventSourceRemove(s);
    loop.eventSourceRemove(watchdog);
    display.destroy();
    shm.deinit();
    cm.deinit();
}
