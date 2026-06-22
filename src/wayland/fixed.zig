const std = @import("std");

/// wl_fixed is a signed 24.8 fixed-point number stored as an i32.
/// The high 24 bits are the integer part and the low 8 bits are the fraction.
pub const Fixed = struct {
    raw: i32,

    /// Create a Fixed from a raw i32 bit pattern.
    pub fn fromRaw(raw: i32) Fixed {
        return .{ .raw = raw };
    }

    /// Create a Fixed from an integer value (no fractional part).
    pub fn fromInt(value: i32) Fixed {
        return .{ .raw = value * 256 };
    }

    /// Create a Fixed from a floating-point double.
    pub fn fromDouble(value: f64) Fixed {
        return .{ .raw = @intFromFloat(value * 256.0) };
    }

    /// Convert to a floating-point double.
    pub fn toDouble(self: Fixed) f64 {
        return @as(f64, @floatFromInt(self.raw)) / 256.0;
    }

    /// Convert to integer (truncates fractional part).
    pub fn toInt(self: Fixed) i32 {
        return @divTrunc(self.raw, 256);
    }
};

test "Fixed.fromInt and toInt round-trip" {
    const f = Fixed.fromInt(42);
    try std.testing.expectEqual(@as(i32, 42), f.toInt());
}

test "Fixed.fromDouble and toDouble round-trip" {
    const f = Fixed.fromDouble(3.5);
    try std.testing.expectApproxEqAbs(3.5, f.toDouble(), 0.004);
}

test "Fixed.fromDouble negative value" {
    const f = Fixed.fromDouble(-1.5);
    try std.testing.expectApproxEqAbs(-1.5, f.toDouble(), 0.004);
}

test "Fixed.fromInt zero" {
    const f = Fixed.fromInt(0);
    try std.testing.expectEqual(@as(i32, 0), f.toInt());
    try std.testing.expectApproxEqAbs(0.0, f.toDouble(), 0.004);
}

test "Fixed raw storage matches 24.8 spec" {
    // 1.0 should be stored as 256 (0x100)
    const f = Fixed.fromDouble(1.0);
    try std.testing.expectEqual(@as(i32, 256), f.raw);
}

test "Fixed fromRaw preserves raw value" {
    const f = Fixed.fromRaw(0x180); // 1.5 in 24.8
    try std.testing.expectApproxEqAbs(1.5, f.toDouble(), 0.004);
}
