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
/// OPTIMIZED: Uses precomputed lookup table
pub fn hostIdx(octet: u8) usize {
    return hostIdxLookupTable[octet];
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
pub const pfxToIdx256LookupTable = blk: {
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

/// Precomputed network mask lookup table
/// netMaskLookupTable[bits] = mask for given bit count
/// Eliminates runtime shifting operations
pub const netMaskLookupTable = [_]u8{
    0b0000_0000, // bits == 0
    0b1000_0000, // bits == 1
    0b1100_0000, // bits == 2
    0b1110_0000, // bits == 3
    0b1111_0000, // bits == 4
    0b1111_1000, // bits == 5
    0b1111_1100, // bits == 6
    0b1111_1110, // bits == 7
    0b1111_1111, // bits == 8
};

/// Precomputed max depth and last bits lookup table
/// maxDepthLastBitsLookupTable[bits] = {max_depth, last_bits}
/// Eliminates runtime division and modulo operations
pub const maxDepthLastBitsLookupTable = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]struct { max_depth: u8, last_bits: u8 } = undefined;
    
    for (0..256) |bits| {
        const max_depth = @as(u8, @intCast(bits / 8));
        const last_bits = @as(u8, @intCast(bits % 8));
        table[bits] = .{ .max_depth = max_depth, .last_bits = last_bits };
    }
    
    break :blk table;
};

/// Precomputed hostIdx lookup table
/// hostIdxLookupTable[octet] = hostIdx(octet)
/// Eliminates runtime addition operations
pub const hostIdxLookupTable = blk: {
    @setEvalBranchQuota(1000);
    var table: [256]usize = undefined;
    
    for (0..256) |octet| {
        table[octet] = @as(usize, octet) + 256;
    }
    
    break :blk table;
};

/// Precomputed idxToPfx256 reverse lookup table
/// idxToPfxLookupTable[idx] = {octet, pfx_len}
/// Eliminates complex reverse calculation
pub const idxToPfxLookupTable = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]struct { octet: u8, pfx_len: u8, valid: bool } = undefined;
    
    // Initialize all entries as invalid
    for (0..256) |i| {
        table[i] = .{ .octet = 0, .pfx_len = 0, .valid = false };
    }
    
    // Precompute valid entries by reverse mapping
    for (0..9) |pfx_len| {
        for (0..256) |octet| {
            const shift: u6 = @intCast(pfx_len);
            const right_shift: u6 = @intCast(8 - pfx_len);
            var idx = (@as(usize, octet) >> right_shift) + (@as(usize, 1) << shift);
            if (idx > 255) {
                idx >>= 1;
            }
            const idx_u8 = @as(u8, @intCast(idx));
            
            // Only set if not already set (prefer lower pfx_len for conflicts)
            if (!table[idx_u8].valid) {
                table[idx_u8] = .{ 
                    .octet = @as(u8, @intCast(octet)), 
                    .pfx_len = @as(u8, @intCast(pfx_len)), 
                    .valid = true 
                };
            }
        }
    }
    
    break :blk table;
};

/// Precomputed isFringe lookup table
/// isFringeLookupTable[depth][bits] = isFringe(depth, bits)
/// Eliminates runtime modulo and comparison operations
pub const isFringeLookupTable = blk: {
    @setEvalBranchQuota(50000);
    var table: [32][256]bool = undefined;
    
    for (0..32) |depth| {
        for (0..256) |bits| {
            const max_depth = bits / 8;
            const last_bits = bits % 8;
            table[depth][bits] = (depth == max_depth - 1) and (last_bits == 0);
        }
    }
    
    break :blk table;
};

/// Return octet and prefix length from base index
/// Inverse function of pfxToIdx256.
/// ULTRA-OPTIMIZED: Uses precomputed lookup table
/// 
/// Returns error for invalid input.
pub fn idxToPfx256(idx: u8) !struct { octet: u8, pfx_len: u8 } {
    const entry = idxToPfxLookupTable[idx];
    if (!entry.valid) {
        return error.InvalidIndex;
    }
    
    return .{
        .octet = entry.octet,
        .pfx_len = entry.pfx_len,
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
/// ULTRA-OPTIMIZED: Uses precomputed lookup table
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
    return netMaskLookupTable[bits];
}

/// Return max_depth (stride数) と last_bits (最後のstride未満のビット数)
/// ULTRA-OPTIMIZED: Uses precomputed lookup table
pub fn maxDepthAndLastBits(bits: u8) struct { max_depth: usize, last_bits: u8 } {
    const entry = maxDepthLastBitsLookupTable[bits];
    return .{ .max_depth = @as(usize, entry.max_depth), .last_bits = entry.last_bits };
}

/// isFringe: leaves with /8, /16, ... /128 bits at special positions
/// in the trie. Go実装のisFringeを移植
/// ULTRA-OPTIMIZED: Uses precomputed lookup table
pub fn isFringe(depth: usize, bits: u8) bool {
    if (depth >= 32) return false; // Bounds check
    return isFringeLookupTable[depth][bits];
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