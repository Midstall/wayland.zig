//! wl_global: a server-advertised, bindable interface instance.
//!
//! Mirrors libwayland's `struct wl_global` (src/wayland-server.c). A Global
//! lives on the Display's global_list and is advertised to every client that
//! has a wl_registry. When a client binds it (wl_registry.bind), the runtime
//! creates a resource at the client's new_id and calls the Global's `bind`
//! callback, which sets up the resource's implementation.
//!
//! A monotonically increasing `name` (the registry name, distinct from the
//! interface name) identifies the global on the wire. Globals are advertised
//! by wl_registry.global(name, interface, version) and revoked by
//! wl_registry.global_remove(name).

const std = @import("std");
const Link = @import("list.zig").Link;
const Interface = @import("interface.zig").Interface;

// Forward references resolved at use sites (avoid an import cycle with
// server_client.zig / display.zig, which import this file).
const Client = @import("server_client.zig").Client;
const Display = @import("display.zig").Display;

/// The bind callback: invoked when a client binds this global. It is handed the
/// binding client, the global's user data, the (capped) version requested, and
/// the new object id to create the resource at. The callback typically calls
/// `Object.create` + `setImplementation`. Mirrors wl_global_bind_func_t.
pub const BindFn = *const fn (client: *Client, data: ?*anyopaque, version: u32, id: u32) void;

pub const Global = struct {
    interface: *const Interface,
    version: u32,
    bind: BindFn,
    data: ?*anyopaque,
    /// The registry name (monotonic, assigned by Display.globalCreate). Not the
    /// interface name.
    name: u32,
    link: Link,
    display: *Display,

    /// Remove this global: advertise its removal to every bound registry,
    /// unlink it from the display, and free it. Mirrors wl_global_destroy /
    /// wl_global_remove + the free. After this the pointer is invalid.
    pub fn destroy(self: *Global) void {
        self.display.advertiseGlobalRemove(self.name);
        self.link.remove();
        self.display.allocator.destroy(self);
    }
};
