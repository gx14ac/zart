//! Prefix and base index conversion functionality
//! 
//! This module provides conversion between prefixes (octet and prefix length)
//! and base indices.
//! 
//! Main features:
//! - Convert prefix to index
//! - Convert index to prefix
//! - Calculate host address index
//! - Calculate prefix length and range

const std = @import("std");

/// Calculate host address index
/// This is a fast version of PfxToIdx(octet/8).
pub fn hostIdx(octet: u8) usize {
    return @as(usize, octet) + 256;
}

/// Map 8-bit prefix to numeric value
/// Prefixes range from 0/0 to 255/8, mapped values range from 1 to 511.
/// 
/// Example: octet/pfxLen: 160/3 = 0b1010_0000/3 => idxToPfx(160/3) => 13
/// 
///     0b1010_0000 => 0b0000_0101
///      ^^^ >> (8-3)         ^^^
/// 
///     0b0000_0001 => 0b0000_1000
///               ^ << 3      ^
///      + -----------------------
///                0b0000_1101 = 13
fn pfxToIdx(octet: u8, pfx_len: u8) usize {
    std.debug.assert(pfx_len <= 63);
    const shift: u6 = @intCast(pfx_len);
    const right_shift: u6 = @intCast(8 - pfx_len);
    return (@as(usize, octet) >> right_shift) + (@as(usize, 1) << shift);
}

/// Map 8-bit prefix to numeric value (256 version)
/// Value range is [1..255]. Values greater than 255 are shifted by >>1.
pub fn pfxToIdx256(octet: u8, pfx_len: u8) u8 {
    const idx = pfxToIdx(octet, pfx_len);
    if (idx > 255) {
        return @as(u8, @intCast(idx >> 1));
    }
    return @as(u8, @intCast(idx));
}

/// Return octet and prefix length from base index
/// Inverse function of pfxToIdx256.
/// 
/// Returns error for invalid input.
pub fn idxToPfx256(idx: u8) !struct { octet: u8, pfx_len: u8 } {
    if (idx == 0) {
        return error.InvalidIndex;
    }

    const pfx_len = @as(u8, @intCast(std.math.log2_int(u8, idx)));
    const shift_bits = 8 - pfx_len;
    const mask = @as(u8, 0xff) >> @intCast(shift_bits);
    const octet = (idx & mask) << @intCast(shift_bits);

    return .{
        .octet = octet,
        .pfx_len = pfx_len,
    };
}

/// Calculate prefix length from depth and index
pub fn pfxLen256(depth: i32, idx: u8) !u8 {
    if (idx == 0) {
        return error.InvalidIndex;
    }
    return @as(u8, @intCast(depth * 8 + std.math.log2_int(u8, idx)));
}

/// Return range (first and last octet) from prefix index
pub fn idxToRange256(idx: u8) !struct { first: u8, last: u8 } {
    const pfx = try idxToPfx256(idx);
    const last = pfx.octet | ~netMask(pfx.pfx_len);
    return .{
        .first = pfx.octet,
        .last = last,
    };
}

/// Generate network mask based on bit count
/// 
/// 0b0000_0000, // bits == 0
/// 0b1000_0000, // bits == 1
/// 0b1100_0000, // bits == 2
/// 0b1110_0000, // bits == 3
/// 0b1111_0000, // bits == 4
/// 0b1111_1000, // bits == 5
/// 0b1111_1100, // bits == 6
/// 0b1111_1110, // bits == 7
/// 0b1111_1111, // bits == 8
pub fn netMask(bits: u8) u8 {
    std.debug.assert(bits <= 8);
    if (bits == 0) return 0;
    const shift: u3 = @intCast(8 - bits);
    return @as(u8, 0xff) << shift;
}

// Tests
test "base_index" {
    // Test HostIdx
    try std.testing.expectEqual(@as(usize, 256), hostIdx(0));
    try std.testing.expectEqual(@as(usize, 257), hostIdx(1));
    try std.testing.expectEqual(@as(usize, 511), hostIdx(255));

    // Test PfxToIdx256
    try std.testing.expectEqual(@as(u8, 13), pfxToIdx256(160, 3));
    try std.testing.expectEqual(@as(u8, 1), pfxToIdx256(0, 0));
    try std.testing.expectEqual(@as(u8, 255), pfxToIdx256(255, 8));

    // Test IdxToPfx256
    const pfx1 = try idxToPfx256(13);
    try std.testing.expectEqual(@as(u8, 160), pfx1.octet);
    try std.testing.expectEqual(@as(u8, 3), pfx1.pfx_len);

    // Test PfxLen256
    try std.testing.expectEqual(@as(u8, 3), try pfxLen256(0, 13));
    try std.testing.expectEqual(@as(u8, 11), try pfxLen256(1, 13));

    // Test IdxToRange256
    const range1 = try idxToRange256(13);
    try std.testing.expectEqual(@as(u8, 160), range1.first);
    try std.testing.expectEqual(@as(u8, 191), range1.last);

    // Test NetMask
    try std.testing.expectEqual(@as(u8, 0b0000_0000), netMask(0));
    try std.testing.expectEqual(@as(u8, 0b1000_0000), netMask(1));
    try std.testing.expectEqual(@as(u8, 0b1111_1111), netMask(8));
} 