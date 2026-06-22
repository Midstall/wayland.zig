//! wl_interface / wl_message: the static protocol descriptions.
//!
//! Mirrors libwayland's `struct wl_interface` and `struct wl_message`
//! (wayland-util.h). A `Message` describes one request or event: its name, its
//! argument signature, and the per-argument interface types (for object/new_id
//! args). An `Interface` is a named, versioned set of request and event
//! Messages. The generator emits these from the protocol XML; here we
//! hand-write the core interfaces (wl_display, wl_registry, wl_callback) that
//! the runtime itself needs to function.
//!
//! Signature characters (libwayland connection.c):
//!   i = int (i32)         u = uint (u32)        f = fixed (wl_fixed)
//!   s = string            o = object            n = new_id
//!   a = array             h = fd
//!   '?' (prefix)          = the following arg is nullable
//!   leading ASCII digits  = the "since" version (skipped when marshalling)
//!
//! Only the type chars (i u f s o n a h) consume a wire word / payload. The
//! '?' and version-digit chars are metadata and are skipped by the codec.

const std = @import("std");

/// One request or event description (wl_message).
pub const Message = struct {
    /// The method name (e.g. "get_registry", "global").
    name: []const u8,
    /// The argument signature (see the char table above).
    signature: []const u8,
    /// One entry per argument, giving the *Interface for object/new_id args
    /// (null for typed-by-the-wire args like the registry.bind new_id, and for
    /// all non-object args). Length matches the number of type chars in
    /// `signature`. May be empty when no arg references an interface.
    types: []const ?*const Interface,
};

/// A named, versioned protocol interface (wl_interface).
pub const Interface = struct {
    name: []const u8,
    version: u32,
    requests: []const Message,
    events: []const Message,

    /// Look up an event by opcode (its index in `events`), or null.
    pub fn event(self: *const Interface, opcode: u16) ?*const Message {
        if (opcode >= self.events.len) return null;
        return &self.events[opcode];
    }

    /// Look up a request by opcode (its index in `requests`), or null.
    pub fn request(self: *const Interface, opcode: u16) ?*const Message {
        if (opcode >= self.requests.len) return null;
        return &self.requests[opcode];
    }
};

/// True if `c` is a wire-consuming type char (skips '?' and version digits).
pub fn isTypeChar(c: u8) bool {
    return switch (c) {
        'i', 'u', 'f', 's', 'o', 'n', 'a', 'h' => true,
        else => false,
    };
}

/// Count the number of type chars (actual arguments) in a signature.
pub fn argCount(signature: []const u8) usize {
    var n: usize = 0;
    for (signature) |c| {
        if (isTypeChar(c)) n += 1;
    }
    return n;
}

const no_types: []const ?*const Interface = &.{};

/// wl_callback: a one-shot done(serial) notification.
pub const wl_callback = Interface{
    .name = "wl_callback",
    .version = 1,
    .requests = &.{},
    .events = &.{
        .{ .name = "done", .signature = "u", .types = &.{null} },
    },
};

/// wl_registry: advertises globals and binds them.
///
/// bind is the special request: libwayland's signature is "usun" - name(u),
/// the interface name(s), the version(u), then the new_id(n) at the bound
/// version. The codec reads (string, uint) dynamically to learn what to make
/// the new_id, as registry_bind does in wayland-server.c.
pub const wl_registry = Interface{
    .name = "wl_registry",
    .version = 1,
    .requests = &.{
        .{ .name = "bind", .signature = "usun", .types = &.{ null, null, null, null } },
    },
    .events = &.{
        .{ .name = "global", .signature = "usu", .types = &.{ null, null, null } },
        .{ .name = "global_remove", .signature = "u", .types = &.{null} },
    },
};

/// wl_display: the implicit object 1. sync + get_registry requests; error +
/// delete_id events.
pub const wl_display = Interface{
    .name = "wl_display",
    .version = 1,
    .requests = &.{
        .{ .name = "sync", .signature = "n", .types = &.{&wl_callback} },
        .{ .name = "get_registry", .signature = "n", .types = &.{&wl_registry} },
    },
    .events = &.{
        .{ .name = "error", .signature = "ous", .types = &.{ null, null, null } },
        .{ .name = "delete_id", .signature = "u", .types = &.{null} },
    },
};

/// wl_display.error codes (the global protocol errors).
pub const DisplayErrorCode = struct {
    pub const invalid_object: u32 = 0;
    pub const invalid_method: u32 = 1;
    pub const no_memory: u32 = 2;
    pub const implementation: u32 = 3;
};

// Event opcodes for the core interfaces (so the runtime does not hard-code
// magic numbers when it posts).
pub const DISPLAY_ERROR: u16 = 0;
pub const DISPLAY_DELETE_ID: u16 = 1;
pub const REGISTRY_GLOBAL: u16 = 0;
pub const REGISTRY_GLOBAL_REMOVE: u16 = 1;
pub const CALLBACK_DONE: u16 = 0;

const testing = std.testing;

test "interface: argCount skips ? and since-version digits" {
    try testing.expectEqual(@as(usize, 0), argCount(""));
    try testing.expectEqual(@as(usize, 1), argCount("u"));
    try testing.expectEqual(@as(usize, 3), argCount("ous"));
    try testing.expectEqual(@as(usize, 4), argCount("usun"));
    // nullable + since-version metadata does not count as args.
    try testing.expectEqual(@as(usize, 2), argCount("2u?o"));
    try testing.expectEqual(@as(usize, 1), argCount("?s"));
}

test "interface: core interfaces have matching type-array lengths" {
    const ifaces = [_]*const Interface{ &wl_display, &wl_registry, &wl_callback };
    for (ifaces) |iface| {
        for (iface.requests) |m| {
            try testing.expectEqual(argCount(m.signature), m.types.len);
        }
        for (iface.events) |m| {
            try testing.expectEqual(argCount(m.signature), m.types.len);
        }
    }
}

test "interface: event/request lookup by opcode" {
    try testing.expectEqualStrings("error", wl_display.event(DISPLAY_ERROR).?.name);
    try testing.expectEqualStrings("delete_id", wl_display.event(DISPLAY_DELETE_ID).?.name);
    try testing.expectEqualStrings("get_registry", wl_display.request(1).?.name);
    try testing.expect(wl_display.event(5) == null);
    try testing.expectEqualStrings("global", wl_registry.event(REGISTRY_GLOBAL).?.name);
    try testing.expectEqualStrings("done", wl_callback.event(CALLBACK_DONE).?.name);
}
