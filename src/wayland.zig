//! Root of the abstract, zero-C-dep Wayland library (one `wayland` module).
//! Consumers reach the pieces as namespaces: `wayland.client`, `wayland.server`,
//! `wayland.shm`, plus the core wire primitives (`wayland.wire`, `wayland.fixed`).

const std = @import("std");

pub const name = "wayland";

pub const fixed = @import("wayland/fixed.zig");
pub const wire = @import("wayland/wire.zig");
pub const list = @import("wayland/list.zig");
pub const array = @import("wayland/array.zig");
pub const signal = @import("wayland/signal.zig");
pub const event_loop = @import("wayland/event_loop.zig");
pub const shm = @import("wayland/shm.zig");
pub const client = @import("wayland/client.zig");
pub const connection = @import("wayland/connection.zig");
pub const interface = @import("wayland/interface.zig");
pub const argument = @import("wayland/argument.zig");
pub const global = @import("wayland/global.zig");
pub const display = @import("wayland/display.zig");
pub const server_client = @import("wayland/server_client.zig");
pub const server = @import("wayland/server.zig");

pub const Fixed = fixed.Fixed;
pub const WireError = wire.WireError;
pub const Writer = wire.Writer;
pub const Reader = wire.Reader;

pub const Link = list.Link;
pub const Array = array.Array;
pub const Signal = signal.Signal;
pub const Listener = signal.Listener;
pub const EventLoop = event_loop.EventLoop;
pub const EventSource = event_loop.EventSource;

pub const Display = display.Display;
pub const ServerClient = server_client.Client;
pub const Object = server_client.Object;
pub const Resource = server_client.Object;
pub const Connection = connection.Connection;
pub const Interface = interface.Interface;
pub const Message = interface.Message;
pub const Argument = argument.Argument;
pub const Global = global.Global;

test {
    std.testing.refAllDecls(@This());
}
