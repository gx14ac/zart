const std = @import("std");

/// ART (Adaptive Radix Tree) baseIndex implementation
/// Maps prefixes to complete binary tree indices
/// 
/// This is the core of the ART algorithm from the paper.
/// Go BART implementation: bart/internal/art/base_index.go

/// HostIdx is just PfxToIdx(octet/8) but faster.
pub inline fn hostIdx(octet: u8) u16 {
    return @as(u16, octet) + 256;
}

/// pfxToIdx maps 8bit prefixes to numbers. The prefixes range from 0/0 to 255/8
/// and the mapped values from:
///   [0x0000_00001 .. 0x0000_0001_1111_1111] = [1 .. 511]
///
/// example: octet/pfxLen: 160/3 = 0b1010_0000/3 => pfxToIdx(160/3) => 13
///
///                 0b1010_0000 => 0b0000_0101
///                   ^^^ >> (8-3)         ^^^
///
///                 0b0000_0001 => 0b0000_1000
///                           ^ << 3      ^
///                  + -----------------------
///                                0b0000_1101 = 13
inline fn pfxToIdx(octet: u8, pfx_len: u8) u16 {
    if (pfx_len == 0) {
        return 1; // Special case: 0/0 → 1
    }
    const shift_right = @as(u3, @intCast(8 - pfx_len));
    return @as(u16, octet >> shift_right) + (@as(u16, 1) << @as(u4, @intCast(pfx_len)));
}

/// PfxToIdx256 maps 8bit prefixes to numbers. The values range [1 .. 255].
/// Values > 255 are shifted by >> 1.
pub fn pfxToIdx256(octet: u8, pfx_len: u8) u8 {
    var idx = pfxToIdx(octet, pfx_len);
    if (idx > 255) {
        idx >>= 1;
    }
    return @as(u8, @intCast(idx));
}

/// IdxToPfx256 returns the octet and prefix len of baseIdx.
/// It's the inverse to pfxToIdx256.
/// It panics on invalid input (idx == 0).
pub fn idxToPfx256(idx: u8) struct { octet: u8, pfx_len: u8 } {
    if (idx == 0) {
        @panic("logic error, idx is 0");
    }

    const pfx_len = @as(u8, @intCast(std.math.log2_int(u8, idx)));
    const shift_bits = 8 - pfx_len;

    const mask = if (shift_bits < 8) @as(u8, 0xff) >> @as(u3, @intCast(shift_bits)) else 0;
    const octet = if (shift_bits < 8) (idx & mask) << @as(u3, @intCast(shift_bits)) else 0;

    return .{ .octet = octet, .pfx_len = pfx_len };
}

/// PfxLen256 returns the bits based on depth and idx.
pub fn pfxLen256(depth: u8, idx: u8) u8 {
    if (idx == 0) {
        @panic("logic error, idx is 0");
    }
    return @as(u8, depth) * 8 + @as(u8, @intCast(std.math.log2_int(u8, idx)));
}

/// IdxToRange256 returns the first and last octet of prefix idx.
pub fn idxToRange256(idx: u8) struct { first: u8, last: u8 } {
    const result = idxToPfx256(idx);
    const first = result.octet;
    const last = first | ~netMask(result.pfx_len);
    return .{ .first = first, .last = last };
}

/// NetMask for bits
///   0b0000_0000, // bits == 0
///   0b1000_0000, // bits == 1
///   0b1100_0000, // bits == 2
///   0b1110_0000, // bits == 3
///   0b1111_0000, // bits == 4
///   0b1111_1000, // bits == 5
///   0b1111_1100, // bits == 6
///   0b1111_1110, // bits == 7
///   0b1111_1111, // bits == 8
pub fn netMask(bits: u8) u8 {
    if (bits == 0) return 0b0000_0000;
    if (bits >= 8) return 0b1111_1111;
    return @as(u8, 0b1111_1111) << @as(u3, @intCast(8 - bits));
}

test "ART baseIndex mapping" {
    const testing = std.testing;

    // Test pfxToIdx256
    try testing.expectEqual(@as(u8, 1), pfxToIdx256(0, 0));     // 0/0 → 1
    try testing.expectEqual(@as(u8, 2), pfxToIdx256(0, 1));     // 0/1 → 2
    try testing.expectEqual(@as(u8, 3), pfxToIdx256(128, 1));   // 128/1 → 3
    try testing.expectEqual(@as(u8, 21), pfxToIdx256(80, 4));   // 80/4 → 21
    try testing.expectEqual(@as(u8, 255), pfxToIdx256(255, 7)); // 255/7 → 255
    try testing.expectEqual(@as(u8, 128), pfxToIdx256(0, 8));   // 0/8 → 128 (256>>1)
    try testing.expectEqual(@as(u8, 255), pfxToIdx256(255, 8)); // 255/8 → 255 (511>>1)

    // Test idxToPfx256
    const test1 = idxToPfx256(1);
    try testing.expectEqual(@as(u8, 0), test1.octet);
    try testing.expectEqual(@as(u8, 0), test1.pfx_len);

    const test2 = idxToPfx256(15);
    try testing.expectEqual(@as(u8, 224), test2.octet);
    try testing.expectEqual(@as(u8, 3), test2.pfx_len);

    const test3 = idxToPfx256(255);
    try testing.expectEqual(@as(u8, 254), test3.octet);
    try testing.expectEqual(@as(u8, 7), test3.pfx_len);

    // Test idxToRange256
    const range1 = idxToRange256(1);
    try testing.expectEqual(@as(u8, 0), range1.first);
    try testing.expectEqual(@as(u8, 255), range1.last);

    const range2 = idxToRange256(2);
    try testing.expectEqual(@as(u8, 0), range2.first);
    try testing.expectEqual(@as(u8, 127), range2.last);

    const range3 = idxToRange256(3);
    try testing.expectEqual(@as(u8, 128), range3.first);
    try testing.expectEqual(@as(u8, 255), range3.last);
} 