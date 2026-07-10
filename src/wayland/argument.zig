//! wl_argument + the per-signature marshal/demarshal codec.
//!
//! Mirrors libwayland's `union wl_argument` and the heart of connection.c
//! (wl_closure_marshal / wl_connection_demarshal). An `Argument` is one decoded
//! protocol value; `marshal` encodes a header + a slice of Arguments per a
//! signature onto a Connection, and `demarshal` decodes a received request body
//! per a signature into a caller-provided slice.
//!
//! Wire layout (little-endian u32 words, all args 4-byte aligned):
//!   i u f o n  -> one u32 word
//!   s          -> u32 length (bytes INCLUDING the NUL) then bytes + NUL,
//!                 padded to 4. length 0 encodes a null string.
//!   a          -> u32 length (bytes) then bytes, padded to 4.
//!   h (fd)     -> not in the data stream: queued on the connection's out-fd
//!                 list on marshal, pulled from the in-fd queue on demarshal.
//!
//! Signature metadata ('?' nullable, leading digits = since-version) is skipped
//! by both directions: only the type chars consume words/payload.

const std = @import("std");
const Fixed = @import("fixed.zig").Fixed;
const wire = @import("wire.zig");
const interface = @import("interface.zig");
const Connection = @import("connection.zig").Connection;
const FdQueue = @import("FdQueue.zig");

pub const ArgError = error{
    OutOfMemory,
    BufferFull,
    SignatureArgMismatch,
    MissingFd,
    Truncated,
} || wire.WireError;

/// One decoded protocol argument (wl_argument). The tag is chosen by the
/// caller to match the signature char; marshal validates the pairing.
pub const Argument = union(enum) {
    int: i32,
    uint: u32,
    fixed: Fixed,
    string: ?[]const u8,
    object: ?u32, // object id (0 == null)
    new_id: u32,
    array: ?[]const u8,
    fd: i32,
};

/// True if `arg` is the right variant for signature char `c`.
fn matches(c: u8, arg: Argument) bool {
    return switch (c) {
        'i' => arg == .int,
        'u' => arg == .uint,
        'f' => arg == .fixed,
        's' => arg == .string,
        'o' => arg == .object,
        'n' => arg == .new_id,
        'a' => arg == .array,
        'h' => arg == .fd,
        else => false,
    };
}

/// Encode a message (header + args) onto `conn` for `sender_id`/`opcode`,
/// following `signature`. fds are queued out-of-band on the connection rather
/// than written into the byte stream. The bytes (and any fds) are queued for
/// the next flush.
pub fn marshal(
    conn: *Connection,
    allocator: std.mem.Allocator,
    sender_id: u32,
    opcode: u16,
    signature: []const u8,
    args: []const Argument,
) ArgError!void {
    var w = wire.Writer.init();
    defer w.deinit(allocator);
    try w.begin(allocator, sender_id, opcode);

    // Up to MAX_FDS_OUT (28) fds per message in practice; a small fixed buffer
    // is plenty for the core protocol (error/global/done carry none).
    var fds: [28]i32 = undefined;
    var fd_count: usize = 0;

    var ai: usize = 0;
    for (signature) |c| {
        if (!interface.isTypeChar(c)) continue; // skip '?' and version digits
        if (ai >= args.len) return error.SignatureArgMismatch;
        const arg = args[ai];
        ai += 1;
        if (!matches(c, arg)) return error.SignatureArgMismatch;
        switch (c) {
            'i' => try w.writeInt(allocator, arg.int),
            'u' => try w.writeUint(allocator, arg.uint),
            'f' => try w.writeFixed(allocator, arg.fixed),
            's' => try w.writeString(allocator, arg.string),
            'o' => try w.writeObject(allocator, arg.object orelse 0),
            'n' => try w.writeNewId(allocator, arg.new_id),
            'a' => try w.writeArray(allocator, arg.array orelse &.{}),
            'h' => {
                if (fd_count >= fds.len) return error.BufferFull;
                fds[fd_count] = arg.fd;
                fd_count += 1;
            },
            else => unreachable,
        }
    }
    if (ai != args.len) return error.SignatureArgMismatch;

    const bytes = w.finish();
    conn.queueMessage(bytes, fds[0..fd_count]) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.BufferFull => error.BufferFull,
        else => error.BufferFull,
    };
}

/// Decode a received request body from `reader` per `signature` into `out`.
/// `out.len` must equal the signature's arg count. fds are pulled from `fds`, the
/// incoming SCM_RIGHTS queue (may be null when the signature has no 'h' chars).
/// Both connection layers hold a shared `FdQueue`, so either can feed this.
/// Strings/arrays alias the reader's buffer (no copy).
pub fn demarshal(
    reader: *wire.Reader,
    fds: ?*FdQueue,
    signature: []const u8,
    out: []Argument,
) ArgError!void {
    var ai: usize = 0;
    for (signature) |c| {
        if (!interface.isTypeChar(c)) continue;
        if (ai >= out.len) return error.SignatureArgMismatch;
        out[ai] = switch (c) {
            'i' => .{ .int = try reader.readInt() },
            'u' => .{ .uint = try reader.readUint() },
            'f' => .{ .fixed = try reader.readFixed() },
            's' => .{ .string = try reader.readString() },
            'o' => blk: {
                const id = try reader.readObject();
                break :blk .{ .object = if (id == 0) null else id };
            },
            'n' => .{ .new_id = try reader.readNewId() },
            'a' => .{ .array = try reader.readArray() },
            'h' => blk: {
                const q = fds orelse return error.MissingFd;
                const fd = q.takeFd() orelse return error.MissingFd;
                break :blk .{ .fd = fd };
            },
            else => unreachable,
        };
        ai += 1;
    }
    if (ai != out.len) return error.SignatureArgMismatch;
}

const testing = std.testing;
const linux = std.os.linux;
const posix = std.posix;

fn socketpair() ![2]i32 {
    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0, &fds);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    return fds;
}

test "argument: marshal then demarshal a usu (global) message round-trips" {
    const allocator = testing.allocator;
    const pair = try socketpair();
    var a = Connection.init(pair[0]);
    var b = Connection.init(pair[1]);
    defer a.close();
    defer b.close();

    const args = [_]Argument{
        .{ .uint = 7 },
        .{ .string = "wl_compositor" },
        .{ .uint = 4 },
    };
    try marshal(&a, allocator, 2, interface.REGISTRY_GLOBAL, "usu", &args);
    try a.flush();

    _ = try b.read();
    var buf: [256]u8 = undefined;
    const size = (try b.peekMessage(&buf)).?;
    var r = try wire.Reader.init(buf[0..size]);
    try testing.expectEqual(@as(u32, 2), r.object_id);
    try testing.expectEqual(interface.REGISTRY_GLOBAL, r.opcode);

    var decoded: [3]Argument = undefined;
    try demarshal(&r, &b.recv, "usu", &decoded);
    try testing.expectEqual(@as(u32, 7), decoded[0].uint);
    try testing.expectEqualStrings("wl_compositor", decoded[1].string.?);
    try testing.expectEqual(@as(u32, 4), decoded[2].uint);
    b.consume(size);
}

test "argument: marshal then demarshal a bind (usun) request" {
    const allocator = testing.allocator;
    const pair = try socketpair();
    var a = Connection.init(pair[0]);
    var b = Connection.init(pair[1]);
    defer a.close();
    defer b.close();

    const args = [_]Argument{
        .{ .uint = 1 }, // name
        .{ .string = "wl_compositor" }, // interface
        .{ .uint = 4 }, // version
        .{ .new_id = 3 }, // new_id
    };
    try marshal(&a, allocator, 2, 0, "usun", &args);
    try a.flush();

    _ = try b.read();
    var buf: [256]u8 = undefined;
    const size = (try b.peekMessage(&buf)).?;
    var r = try wire.Reader.init(buf[0..size]);
    var decoded: [4]Argument = undefined;
    try demarshal(&r, &b.recv, "usun", &decoded);
    try testing.expectEqual(@as(u32, 1), decoded[0].uint);
    try testing.expectEqualStrings("wl_compositor", decoded[1].string.?);
    try testing.expectEqual(@as(u32, 4), decoded[2].uint);
    try testing.expectEqual(@as(u32, 3), decoded[3].new_id);
    b.consume(size);
}

test "argument: error (ous) message round-trips with object and message" {
    const allocator = testing.allocator;
    const pair = try socketpair();
    var a = Connection.init(pair[0]);
    var b = Connection.init(pair[1]);
    defer a.close();
    defer b.close();

    const args = [_]Argument{
        .{ .object = 5 },
        .{ .uint = 1 },
        .{ .string = "bad object" },
    };
    try marshal(&a, allocator, 1, interface.DISPLAY_ERROR, "ous", &args);
    try a.flush();

    _ = try b.read();
    var buf: [256]u8 = undefined;
    const size = (try b.peekMessage(&buf)).?;
    var r = try wire.Reader.init(buf[0..size]);
    var decoded: [3]Argument = undefined;
    try demarshal(&r, &b.recv, "ous", &decoded);
    try testing.expectEqual(@as(u32, 5), decoded[0].object.?);
    try testing.expectEqual(@as(u32, 1), decoded[1].uint);
    try testing.expectEqualStrings("bad object", decoded[2].string.?);
    b.consume(size);
}

test "argument: fd travels out-of-band (h not in the data stream)" {
    const allocator = testing.allocator;
    const pair = try socketpair();
    var a = Connection.init(pair[0]);
    var b = Connection.init(pair[1]);
    defer a.close();
    defer b.close();

    const efd: i32 = @intCast(linux.eventfd(0, linux.EFD.CLOEXEC));
    defer _ = linux.close(efd);

    const args = [_]Argument{ .{ .uint = 42 }, .{ .fd = efd } };
    try marshal(&a, allocator, 9, 0, "uh", &args);
    try a.flush();

    _ = try b.read();
    var buf: [64]u8 = undefined;
    const size = (try b.peekMessage(&buf)).?;
    // The fd is not in the body: header(8) + one u32 = 12 bytes only.
    try testing.expectEqual(@as(usize, 12), size);
    var r = try wire.Reader.init(buf[0..size]);
    var decoded: [2]Argument = undefined;
    try demarshal(&r, &b.recv, "uh", &decoded);
    try testing.expectEqual(@as(u32, 42), decoded[0].uint);
    try testing.expect(decoded[1].fd >= 0);
    try testing.expect(decoded[1].fd != efd);
    _ = linux.close(decoded[1].fd);
    b.consume(size);
}

test "argument: mismatched arg variant is rejected" {
    const allocator = testing.allocator;
    const pair = try socketpair();
    var a = Connection.init(pair[0]);
    defer a.close();
    _ = linux.close(pair[1]);

    const args = [_]Argument{.{ .int = -1 }}; // 'u' expects .uint
    try testing.expectError(error.SignatureArgMismatch, marshal(&a, allocator, 1, 0, "u", &args));
}
