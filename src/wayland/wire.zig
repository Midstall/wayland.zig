const std = @import("std");
const Fixed = @import("fixed.zig").Fixed;

/// Error set for wire codec operations.
pub const WireError = error{
    BufferTooSmall,
    InvalidLength,
    MessageTruncated,
    StringNotTerminated,
};

/// Wire message writer. Builds a flat byte buffer containing a single
/// Wayland message: 8-byte header + argument words.
///
/// Usage:
///   var w = Writer.init();
///   defer w.deinit(allocator);
///   try w.begin(allocator, object_id, opcode);
///   try w.writeInt(allocator, -1);
///   try w.writeUint(allocator, 42);
///   const buf = w.finish(); // fills in the size field
pub const Writer = struct {
    buf: std.ArrayList(u8),

    pub fn init() Writer {
        return .{ .buf = .empty };
    }

    pub fn deinit(self: *Writer, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
    }

    /// Write the 8-byte message header. object_id and opcode are stored;
    /// the size field is written as 0 and filled in by finish().
    pub fn begin(self: *Writer, allocator: std.mem.Allocator, object_id: u32, opcode: u16) !void {
        // Reset buffer for reuse.
        self.buf.clearRetainingCapacity();
        // word0: object id
        try appendU32(self, allocator, object_id);
        // word1: (size << 16) | opcode - size placeholder = 0
        const word1: u32 = @as(u32, opcode);
        try appendU32(self, allocator, word1);
    }

    /// Patch the size field in word1 and return a slice of the buffer.
    /// The returned slice is valid until the next mutation of Writer.
    pub fn finish(self: *Writer) []const u8 {
        const size: u16 = @intCast(self.buf.items.len);
        const opcode_low: u16 = @truncate(readU32LE(self.buf.items[4..8]));
        const word1: u32 = (@as(u32, size) << 16) | @as(u32, opcode_low);
        writeU32LE(self.buf.items[4..8], word1);
        return self.buf.items;
    }

    /// Append a signed 32-bit integer argument.
    pub fn writeInt(self: *Writer, allocator: std.mem.Allocator, value: i32) !void {
        try appendU32(self, allocator, @bitCast(value));
    }

    /// Append an unsigned 32-bit integer argument.
    pub fn writeUint(self: *Writer, allocator: std.mem.Allocator, value: u32) !void {
        try appendU32(self, allocator, value);
    }

    /// Append an object id argument (same encoding as uint).
    pub fn writeObject(self: *Writer, allocator: std.mem.Allocator, id: u32) !void {
        try appendU32(self, allocator, id);
    }

    /// Append a new_id argument (same encoding as uint).
    pub fn writeNewId(self: *Writer, allocator: std.mem.Allocator, id: u32) !void {
        try appendU32(self, allocator, id);
    }

    /// Append a wl_fixed argument.
    pub fn writeFixed(self: *Writer, allocator: std.mem.Allocator, f: Fixed) !void {
        try appendU32(self, allocator, @bitCast(f.raw));
    }

    /// Append a string argument.
    /// Pass null to encode a null string (length word = 0, no data).
    /// Otherwise encodes: u32 len (bytes including NUL), string bytes + NUL, padding.
    pub fn writeString(self: *Writer, allocator: std.mem.Allocator, s: ?[]const u8) !void {
        if (s == null) {
            try appendU32(self, allocator, 0);
            return;
        }
        const str = s.?;
        // length includes the NUL terminator
        const len: u32 = @intCast(str.len + 1);
        try appendU32(self, allocator, len);
        try self.buf.appendSlice(allocator, str);
        // NUL terminator
        try self.buf.append(allocator, 0);
        // pad to 4-byte boundary
        const total = str.len + 1;
        const pad = alignPad(total);
        var i: usize = 0;
        while (i < pad) : (i += 1) {
            try self.buf.append(allocator, 0);
        }
    }

    /// Append an array argument: u32 byte-count, followed by the bytes,
    /// padded to the next 4-byte boundary.
    pub fn writeArray(self: *Writer, allocator: std.mem.Allocator, data: []const u8) !void {
        const len: u32 = @intCast(data.len);
        try appendU32(self, allocator, len);
        try self.buf.appendSlice(allocator, data);
        const pad = alignPad(data.len);
        var i: usize = 0;
        while (i < pad) : (i += 1) {
            try self.buf.append(allocator, 0);
        }
    }

    fn appendU32(self: *Writer, allocator: std.mem.Allocator, value: u32) !void {
        var tmp: [4]u8 = undefined;
        writeU32LE(&tmp, value);
        try self.buf.appendSlice(allocator, &tmp);
    }
};

/// Wire message reader. Parses a flat byte buffer produced by Writer.
pub const Reader = struct {
    buf: []const u8,
    pos: usize,

    /// Header fields populated by init().
    object_id: u32,
    opcode: u16,
    size: u16,

    /// Parse the message header from `buf`. `buf` must contain at least the
    /// full message (size bytes). Returns error if buf is too small.
    pub fn init(buf: []const u8) WireError!Reader {
        if (buf.len < 8) return WireError.BufferTooSmall;
        const word0 = readU32LE(buf[0..4]);
        const word1 = readU32LE(buf[4..8]);
        const object_id = word0;
        const opcode: u16 = @truncate(word1 & 0xFFFF);
        const size: u16 = @truncate(word1 >> 16);
        if (buf.len < size) return WireError.MessageTruncated;
        return Reader{
            .buf = buf,
            .pos = 8,
            .object_id = object_id,
            .opcode = opcode,
            .size = size,
        };
    }

    /// Peek just the header (object_id, opcode, size) WITHOUT requiring the
    /// full `size`-byte message to be present. Use this to learn the message
    /// length before the body has been read off the socket; call `init` once
    /// the whole message is in the buffer.
    pub fn parseHeader(buf: []const u8) WireError!Reader {
        if (buf.len < 8) return WireError.BufferTooSmall;
        const word1 = readU32LE(buf[4..8]);
        return Reader{
            .buf = buf,
            .pos = 8,
            .object_id = readU32LE(buf[0..4]),
            .opcode = @truncate(word1 & 0xFFFF),
            .size = @truncate(word1 >> 16),
        };
    }

    /// Read a signed 32-bit integer argument.
    pub fn readInt(self: *Reader) WireError!i32 {
        const raw = try self.readU32();
        return @bitCast(raw);
    }

    /// Read an unsigned 32-bit integer argument.
    pub fn readUint(self: *Reader) WireError!u32 {
        return self.readU32();
    }

    /// Read an object id argument.
    pub fn readObject(self: *Reader) WireError!u32 {
        return self.readU32();
    }

    /// Read a new_id argument.
    pub fn readNewId(self: *Reader) WireError!u32 {
        return self.readU32();
    }

    /// Read a wl_fixed argument.
    pub fn readFixed(self: *Reader) WireError!Fixed {
        const raw = try self.readU32();
        return Fixed.fromRaw(@bitCast(raw));
    }

    /// Read a string argument. Returns null for null strings (length == 0).
    /// Returns a slice into the underlying buffer (no allocation).
    /// The slice does not include the NUL terminator.
    pub fn readString(self: *Reader) WireError!?[]const u8 {
        const len = try self.readU32();
        if (len == 0) return null;
        // len includes NUL terminator
        const data_len = len;
        if (self.pos + data_len > self.size) return WireError.MessageTruncated;
        const start = self.pos;
        self.pos += data_len;
        // skip padding
        self.pos += alignPad(data_len);
        // verify NUL at end
        if (self.buf[start + data_len - 1] != 0) return WireError.StringNotTerminated;
        // return slice without NUL
        return self.buf[start .. start + data_len - 1];
    }

    /// Read an array argument. Returns a slice into the underlying buffer.
    pub fn readArray(self: *Reader) WireError![]const u8 {
        const len = try self.readU32();
        if (self.pos + len > self.size) return WireError.MessageTruncated;
        const start = self.pos;
        self.pos += len;
        self.pos += alignPad(len);
        return self.buf[start .. start + len];
    }

    fn readU32(self: *Reader) WireError!u32 {
        if (self.pos + 4 > self.size) return WireError.MessageTruncated;
        const v = readU32LE(self.buf[self.pos..][0..4]);
        self.pos += 4;
        return v;
    }
};

/// Number of zero padding bytes needed to align `n` up to 4.
fn alignPad(n: usize) usize {
    return (4 - (n % 4)) % 4;
}

fn readU32LE(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn writeU32LE(bytes: []u8, value: u32) void {
    std.mem.writeInt(u32, bytes[0..4], value, .little);
}

test "wire: encode and decode a uint argument" {
    const allocator = std.testing.allocator;
    var w = Writer.init();
    defer w.deinit(allocator);

    try w.begin(allocator, 1, 0);
    try w.writeUint(allocator, 99);
    const buf = w.finish();

    var r = try Reader.init(buf);
    try std.testing.expectEqual(@as(u32, 1), r.object_id);
    try std.testing.expectEqual(@as(u16, 0), r.opcode);
    try std.testing.expectEqual(@as(u16, 12), r.size);
    try std.testing.expectEqual(@as(u32, 99), try r.readUint());
}

test "wire: encode and decode an int argument" {
    const allocator = std.testing.allocator;
    var w = Writer.init();
    defer w.deinit(allocator);

    try w.begin(allocator, 2, 3);
    try w.writeInt(allocator, -42);
    const buf = w.finish();

    var r = try Reader.init(buf);
    try std.testing.expectEqual(@as(i32, -42), try r.readInt());
}

test "wire: header opcode and object_id are correct" {
    const allocator = std.testing.allocator;
    var w = Writer.init();
    defer w.deinit(allocator);

    try w.begin(allocator, 7, 15);
    const buf = w.finish();

    const r = try Reader.init(buf);
    try std.testing.expectEqual(@as(u32, 7), r.object_id);
    try std.testing.expectEqual(@as(u16, 15), r.opcode);
    try std.testing.expectEqual(@as(u16, 8), r.size);
}

test "wire: encode and decode fixed" {
    const allocator = std.testing.allocator;
    var w = Writer.init();
    defer w.deinit(allocator);

    try w.begin(allocator, 1, 0);
    try w.writeFixed(allocator, Fixed.fromDouble(3.14));
    const buf = w.finish();

    var r = try Reader.init(buf);
    const f = try r.readFixed();
    try std.testing.expectApproxEqAbs(3.14, f.toDouble(), 0.004);
}

test "wire: encode and decode a non-null string" {
    const allocator = std.testing.allocator;
    var w = Writer.init();
    defer w.deinit(allocator);

    try w.begin(allocator, 1, 0);
    try w.writeString(allocator, "hello");
    const buf = w.finish();

    var r = try Reader.init(buf);
    const s = try r.readString();
    try std.testing.expect(s != null);
    try std.testing.expectEqualStrings("hello", s.?);
}

test "wire: encode and decode null string" {
    const allocator = std.testing.allocator;
    var w = Writer.init();
    defer w.deinit(allocator);

    try w.begin(allocator, 1, 0);
    try w.writeString(allocator, null);
    const buf = w.finish();

    var r = try Reader.init(buf);
    const s = try r.readString();
    try std.testing.expect(s == null);
}

test "wire: string with length not multiple of 4 is padded correctly" {
    // "abc" has len=3, +1 NUL = 4 bytes, no pad needed
    // "ab" has len=2, +1 NUL = 3 bytes, needs 1 pad byte
    // "a" has len=1, +1 NUL = 2 bytes, needs 2 pad bytes
    // "abcde" has len=5, +1 NUL = 6 bytes, needs 2 pad bytes
    const allocator = std.testing.allocator;

    const cases = [_][]const u8{ "a", "ab", "abc", "abcde", "abcdef", "abcdefg" };
    for (cases) |s| {
        var w = Writer.init();
        defer w.deinit(allocator);

        try w.begin(allocator, 1, 0);
        try w.writeString(allocator, s);
        const buf = w.finish();

        // Total buffer length must be 4-byte aligned
        try std.testing.expect(buf.len % 4 == 0);

        var r = try Reader.init(buf);
        const decoded = try r.readString();
        try std.testing.expect(decoded != null);
        try std.testing.expectEqualStrings(s, decoded.?);
    }
}

test "wire: encode and decode empty string" {
    const allocator = std.testing.allocator;
    var w = Writer.init();
    defer w.deinit(allocator);

    try w.begin(allocator, 1, 0);
    try w.writeString(allocator, "");
    const buf = w.finish();

    try std.testing.expect(buf.len % 4 == 0);

    var r = try Reader.init(buf);
    const s = try r.readString();
    try std.testing.expect(s != null);
    try std.testing.expectEqualStrings("", s.?);
}

test "wire: encode and decode array" {
    const allocator = std.testing.allocator;
    var w = Writer.init();
    defer w.deinit(allocator);

    const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x01 };
    try w.begin(allocator, 1, 0);
    try w.writeArray(allocator, &data);
    const buf = w.finish();

    try std.testing.expect(buf.len % 4 == 0);

    var r = try Reader.init(buf);
    const decoded = try r.readArray();
    try std.testing.expectEqualSlices(u8, &data, decoded);
}

test "wire: round-trip with mixed argument types" {
    const allocator = std.testing.allocator;
    var w = Writer.init();
    defer w.deinit(allocator);

    const arr = [_]u8{ 1, 2, 3 };

    try w.begin(allocator, 42, 7);
    try w.writeInt(allocator, -100);
    try w.writeUint(allocator, 200);
    try w.writeObject(allocator, 5);
    try w.writeNewId(allocator, 6);
    try w.writeFixed(allocator, Fixed.fromDouble(1.5));
    try w.writeString(allocator, "wl_surface");
    try w.writeString(allocator, null);
    try w.writeString(allocator, "");
    try w.writeArray(allocator, &arr);
    const buf = w.finish();

    try std.testing.expect(buf.len % 4 == 0);

    var r = try Reader.init(buf);
    try std.testing.expectEqual(@as(u32, 42), r.object_id);
    try std.testing.expectEqual(@as(u16, 7), r.opcode);
    try std.testing.expectEqual(@as(i32, -100), try r.readInt());
    try std.testing.expectEqual(@as(u32, 200), try r.readUint());
    try std.testing.expectEqual(@as(u32, 5), try r.readObject());
    try std.testing.expectEqual(@as(u32, 6), try r.readNewId());
    const f = try r.readFixed();
    try std.testing.expectApproxEqAbs(1.5, f.toDouble(), 0.004);
    const s1 = try r.readString();
    try std.testing.expectEqualStrings("wl_surface", s1.?);
    const s2 = try r.readString();
    try std.testing.expect(s2 == null);
    const s3 = try r.readString();
    try std.testing.expectEqualStrings("", s3.?);
    const a = try r.readArray();
    try std.testing.expectEqualSlices(u8, &arr, a);
}

test "wire: buffer too small returns error" {
    const buf = [_]u8{ 1, 0, 0, 0 }; // only 4 bytes, need 8 for header
    try std.testing.expectError(WireError.BufferTooSmall, Reader.init(&buf));
}

test "wire: truncated message returns error" {
    // A valid header claiming size=12 but buf only has 8 bytes
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 1, .little); // object_id=1
    std.mem.writeInt(u32, buf[4..8], (@as(u32, 12) << 16) | 3, .little); // size=12, opcode=3
    try std.testing.expectError(WireError.MessageTruncated, Reader.init(&buf));
}

test "wire: parseHeader peeks size without the full message body" {
    // Same shape as the truncated case: header claims size=12, only 8 bytes present.
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 7, .little); // object_id=7
    std.mem.writeInt(u32, buf[4..8], (@as(u32, 12) << 16) | 5, .little); // size=12, opcode=5
    const hdr = try Reader.parseHeader(&buf);
    try std.testing.expectEqual(@as(u32, 7), hdr.object_id);
    try std.testing.expectEqual(@as(u16, 5), hdr.opcode);
    try std.testing.expectEqual(@as(u16, 12), hdr.size);
    // init rejects the same truncated buffer; parseHeader accepts it for peeking.
    try std.testing.expectError(WireError.MessageTruncated, Reader.init(&buf));
}
