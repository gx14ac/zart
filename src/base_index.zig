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
/// OPTIMIZED: Uses precomputed lookup table for maximum performance
pub fn pfxToIdx256(octet: u8, pfx_len: u8) u8 {
    // OPTIMIZATION: Use precomputed lookup table
    if (pfx_len <= 8) {
        return pfxToIdx256LookupTable[pfx_len][octet];
    }
    // Fallback for pfx_len > 8 (rare case)
    var idx = pfxToIdx(octet, pfx_len);
    if (idx > 255) {
        idx >>= 1;
    }
    return @as(u8, @intCast(idx));
}

/// Precomputed lookup table for pfxToIdx256
/// pfxToIdx256LookupTable[pfx_len][octet] = result
/// This eliminates all runtime computation for common cases
const pfxToIdx256LookupTable = blk: {
    @setEvalBranchQuota(100000);
    var table: [9][256]u8 = undefined;
    
    // Precompute for pfx_len 0-8 and all octets 0-255
    for (0..9) |pfx_len| {
        for (0..256) |octet| {
            const shift: u6 = @intCast(pfx_len);
            const right_shift: u6 = @intCast(8 - pfx_len);
            var idx = (@as(usize, octet) >> right_shift) + (@as(usize, 1) << shift);
            if (idx > 255) {
                idx >>= 1;
            }
            table[pfx_len][octet] = @as(u8, @intCast(idx));
        }
    }
    
    break :blk table;
};

/// Return octet and prefix length from base index
/// Inverse function of pfxToIdx256.
/// 
/// Returns error for invalid input.
pub fn idxToPfx256(idx: u8) !struct { octet: u8, pfx_len: u8 } {
    if (idx == 0) {
        return error.InvalidIndex;
    }
    
    // idx == 1 は特別ケース: デフォルトルート (0/0)
    if (idx == 1) {
        return .{
            .octet = 0,
            .pfx_len = 0,
        };
    }

    // Go実装の逆変換ロジック
    // pfxToIdx では: return (octet >> (8-pfx_len)) + (1 << pfx_len)
    // 逆変換: idx = prefix_value + (1 << pfx_len)
    // つまり: prefix_value = idx - (1 << pfx_len)
    
    // pfx_lenを見つける: 最上位ビットの位置
    var pfx_len: u8 = 0;
    var test_val = idx;
    while (test_val > 1) {
        test_val >>= 1;
        pfx_len += 1;
    }
    
    if (pfx_len == 0) {
        return .{
            .octet = 0,
            .pfx_len = 0,
        };
    }
    
    // prefix_value = idx - (1 << pfx_len)
    const base_value = @as(u8, 1) << @as(u3, @intCast(pfx_len));
    if (idx < base_value) {
        return error.InvalidIndex;
    }
    
    const prefix_value = idx - base_value;
    
    // octet = prefix_value << (8 - pfx_len)
    const shift_bits = 8 - pfx_len;
    const octet = if (shift_bits < 8) prefix_value << @as(u3, @intCast(shift_bits)) else 0;

    return .{
        .octet = octet,
        .pfx_len = pfx_len,
    };
}

/// Calculate prefix length from depth and index (Go art.PfxLen256 equivalent)
pub fn pfxLen256(depth: i32, idx: u8) !u8 {
    if (idx == 0) {
        return error.InvalidIndex;
    }
    // Go実装: return uint8(depth<<3 + bits.Len8(idx) - 1)
    const bits_len = @as(u8, @intCast(std.math.log2_int(u8, idx))) + 1;
    return @as(u8, @intCast(depth * 8)) + bits_len - 1;
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

/// Return max_depth (stride数) と last_bits (最後のstride未満のビット数)
pub fn maxDepthAndLastBits(bits: u8) struct { max_depth: usize, last_bits: u8 } {
    const max_depth = bits / 8;
    const last_bits = bits % 8;
    return .{ .max_depth = max_depth, .last_bits = last_bits };
}

/// isFringe: leaves with /8, /16, ... /128 bits at special positions
/// in the trie. Go実装のisFringeを移植
pub fn isFringe(depth: usize, bits: u8) bool {
    const info = maxDepthAndLastBits(bits);
    const max_depth = info.max_depth;
    const last_bits = info.last_bits;
    return depth == max_depth - 1 and last_bits == 0;
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