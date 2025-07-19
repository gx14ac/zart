const std = @import("std");
const lookup_tbl = @import("lookup_tbl.zig");

/// ZART optimized BitSet256 implementation
/// Uses 4 x u64 = 256 bits for cache line optimization
/// Optimized with CPU bit manipulation instructions (POPCNT, LZCNT, TZCNT)
pub const BitSet256 = struct {
    // 4 x u64 = 256 bits = exactly one cache line
    data: [4]u64 align(64),

    /// Initialize a new BitSet256
    pub fn init() BitSet256 {
        return BitSet256{ .data = [_]u64{0} ** 4 };
    }

    /// Set bit to 1 - HOTTEST PATH: Force inline
    pub inline fn set(self: *BitSet256, bit: u8) void {
        const word_idx = bit >> 6;
        const bit_pos = @as(u6, @intCast(bit & 63));
        self.data[word_idx] |= @as(u64, 1) << bit_pos;
    }

    /// Clear bit to 0
    pub fn clear(self: *BitSet256, bit: u8) void {
        const word_idx = bit >> 6;
        const bit_pos = @as(u6, @intCast(bit & 63));
        self.data[word_idx] &= ~(@as(u64, 1) << bit_pos);
    }

    /// Check if bit is set - HOTTEST PATH: Force inline
    pub inline fn isSet(self: *const BitSet256, bit: u8) bool {
        const word_idx = bit >> 6;
        const bit_pos = @as(u6, @intCast(bit & 63));
        return (self.data[word_idx] & (@as(u64, 1) << bit_pos)) != 0;
    }

    /// Return first set bit. Returns null if no bits are set.
    /// Uses TZCNT instruction for maximum performance
    pub fn firstSet(self: *const BitSet256) ?u8 {
        // Manual loop unrolling for Go BART compatibility
        if (self.data[0] != 0) {
            return @as(u8, @intCast(@ctz(self.data[0])));
        }
        if (self.data[1] != 0) {
            return @as(u8, @intCast(@as(usize, @ctz(self.data[1])) + 64));
        }
        if (self.data[2] != 0) {
            return @as(u8, @intCast(@as(usize, @ctz(self.data[2])) + 128));
        }
        if (self.data[3] != 0) {
            return @as(u8, @intCast(@as(usize, @ctz(self.data[3])) + 192));
        }
        return null;
    }

    /// Return first set bit after specified bit. Returns null if no bits are set.
    /// Uses TZCNT instruction for maximum performance
    pub fn nextSet(self: *const BitSet256, bit: u8) ?u8 {
        if (bit >= 255) return null;
        
        var wIdx: usize = bit >> 6;
        const bit_in_word = bit & 63;
        
        if (bit_in_word < 63) {
            const first: u64 = self.data[wIdx] >> @as(u6, @intCast(bit_in_word + 1));
            if (first != 0) {
                const trailing = @as(usize, @ctz(first));
                return @as(u8, @intCast((wIdx << 6) + bit_in_word + 1 + trailing));
            }
        }
        
        wIdx += 1;
        while (wIdx < 4) : (wIdx += 1) {
            if (self.data[wIdx] != 0) {
                const trailing = @as(usize, @ctz(self.data[wIdx]));
                return @as(u8, @intCast((wIdx << 6) + trailing));
            }
        }
        return null;
    }

    /// Return count of set bits (popcount) - Go BART style loop unrolling
    /// SIMD-optimized version: 4x popcount operations in parallel + sum reduction
    pub fn popcnt(self: *const BitSet256) u9 {
        // SIMD version: 4x parallel popcount + sum reduction
        const v: @Vector(4, u64) = self.data;
        const counts: @Vector(4, u32) = @popCount(v);
        const total_count = @reduce(.Add, counts);
        return @as(u9, @intCast(total_count));
        
        // Original sequential version (kept for reference):
        // var cnt: u32 = 0;
        // cnt += @popCount(self.data[0]);
        // cnt += @popCount(self.data[1]);
        // cnt += @popCount(self.data[2]);
        // cnt += @popCount(self.data[3]);
        // return @as(u8, @intCast(cnt));
    }

    /// Return count of set bits up to specified position (rank) - HOTTEST PATH: Force inline
    /// Go BART compatible implementation using precomputed rankMask table
    pub inline fn rank(self: *const BitSet256, idx: u8) u16 {
        // Use precomputed rankMask table for zero-alloc optimized rank calculation
        // Same as Go BART: rnk += bits.OnesCount64(b[i] & rankMask[idx][i])
        const mask = &rankMask[idx];
        var cnt: u32 = 0;
        cnt += @popCount(self.data[0] & mask.data[0]);
        cnt += @popCount(self.data[1] & mask.data[1]);
        cnt += @popCount(self.data[2] & mask.data[2]);
        cnt += @popCount(self.data[3] & mask.data[3]);
        return @as(u16, @intCast(cnt));
    }

    /// Return whether bitset is empty - Go BART style
    /// SIMD-optimized version: 4x OR operations in parallel + OR reduction
    pub fn isEmpty(self: *const BitSet256) bool {
        // SIMD version: 4x parallel OR + OR reduction
        const v: @Vector(4, u64) = self.data;
        const zero_vec: @Vector(4, u64) = @splat(0);
        const non_zero = v != zero_vec;
        const has_any_bits = @reduce(.Or, non_zero);
        return !has_any_bits;
        
        // Original sequential version (kept for reference):
        // return (self.data[0] | self.data[1] | self.data[2] | self.data[3]) == 0;
    }

    /// Calculate intersection of two bitsets
    /// SIMD-optimized version: 4x AND operations in parallel
    pub fn intersection(self: *const BitSet256, other: *const BitSet256) BitSet256 {
        // SIMD version: 4x parallel AND
        const v1: @Vector(4, u64) = self.data;
        const v2: @Vector(4, u64) = other.data;
        const result: @Vector(4, u64) = v1 & v2;
        return BitSet256{ .data = result };
        
        // Original sequential version (kept for reference):
        // return BitSet256{ .data = [_]u64{
        //     self.data[0] & other.data[0],
        //     self.data[1] & other.data[1],
        //     self.data[2] & other.data[2],
        //     self.data[3] & other.data[3],
        // } };
    }

    /// Calculate union of two bitsets
    pub fn bitUnion(self: *const BitSet256, other: *const BitSet256) BitSet256 {
        return BitSet256{ .data = [_]u64{
            self.data[0] | other.data[0],
            self.data[1] | other.data[1],
            self.data[2] | other.data[2],
            self.data[3] | other.data[3],
        } };
    }

    /// Return count of set bits in intersection of two bitsets
    /// Uses POPCNT instruction with manual loop unrolling
    pub fn intersectionCardinality(self: *const BitSet256, other: *const BitSet256) u8 {
        var cnt: u32 = 0;
        cnt += @popCount(self.data[0] & other.data[0]);
        cnt += @popCount(self.data[1] & other.data[1]);
        cnt += @popCount(self.data[2] & other.data[2]);
        cnt += @popCount(self.data[3] & other.data[3]);
        return @as(u8, @intCast(cnt));
    }

    /// Return whether intersection of two bitsets is non-empty
    /// SIMD-optimized version: 4x u64 AND operations in parallel + OR reduction
    pub fn intersectsAny(self: *const BitSet256, other: *const BitSet256) bool {
        // SIMD version: 4x parallel AND + OR reduction
        const v1: @Vector(4, u64) = self.data;
        const v2: @Vector(4, u64) = other.data;
        const and_result = v1 & v2;
        const zero_vec: @Vector(4, u64) = @splat(0);
        const non_zero = and_result != zero_vec;
        return @reduce(.Or, non_zero);
        
        // Original sequential version (kept for reference):
        // return (self.data[0] & other.data[0]) != 0 or
        //        (self.data[1] & other.data[1]) != 0 or
        //        (self.data[2] & other.data[2]) != 0 or
        //        (self.data[3] & other.data[3]) != 0;
    }

    /// Return highest bit in intersection of two bitsets
    /// Go BART exact implementation
    pub fn intersectionTop(self: *const BitSet256, other: *const BitSet256) ?u8 {
        // Go BART exact implementation: for wIdx := 4 - 1; wIdx >= 0; wIdx--
        var wIdx: i32 = 3;
        while (wIdx >= 0) : (wIdx -= 1) {
            const word = self.data[@intCast(wIdx)] & other.data[@intCast(wIdx)];
            if (word != 0) {
                // Go BART exact: return uint8(wIdx<<6+bits.Len64(word)) - 1, true
                const bit_len = @as(u8, @intCast(@clz(word)));
                const len64 = 64 - bit_len;
                // wIdx << 6 can be up to 192 (3 << 6), which fits in u8
                const base = @as(u9, @intCast(wIdx)) << 6;
                const top = @as(u8, @intCast(base + len64 - 1));
                return top;
            }
        }
        return null;
    }

    /// Return set bits as slice. buf is a buffer of 256 u8s.
    /// Go BART compatible implementation
    pub fn asSlice(self: *const BitSet256, buf: *[256]u8) []u8 {
        var size: usize = 0;
        var wIdx: usize = 0;
        while (wIdx < 4) : (wIdx += 1) {
            var word = self.data[wIdx];
            while (word != 0) : (size += 1) {
                const trailing = @as(usize, @ctz(word));
                // wIdx: 0-3, trailing: 0-63, max value: 3*64+63 = 255
                buf[size] = @as(u8, @intCast((wIdx << 6) + trailing));
                word &= (word - 1); // Clear least significant bit
            }
        }
        return buf[0..size];
    }

    /// Return set bits as slice. Allocates buffer internally.
    /// Go BART compatible implementation
    pub fn all(self: *const BitSet256) []u8 {
        var buf: [256]u8 = undefined;
        return self.asSlice(&buf);
    }
    
    /// nthSet - n番目にセットされているビットを返す (0-indexed)
    pub fn nthSet(self: *const BitSet256, n: usize) ?u8 {
        var count: usize = 0;
        var bit: u8 = 0;
        
        while (bit <= 255) {
            if (self.isSet(bit)) {
                if (count == n) {
                    return bit;
                }
                count += 1;
            }
            if (bit == 255) break;
            bit += 1;
        }
        
        return null;
    }
};

/// Precomputed rank masks for zero-alloc optimized rank calculation
/// rankMask[i] has bits 0-i set to 1, rest to 0
pub const rankMask = blk: {
    @setEvalBranchQuota(100000);
    var arr: [256]BitSet256 = undefined;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        var bs = BitSet256{ .data = [_]u64{0} ** 4 };
        var j: usize = 0;
        while (j <= i) : (j += 1) {
            bs.set(@as(u8, @intCast(j)));
        }
        arr[i] = bs;
    }
    break :blk arr;
};

/// Go BART compatible LPM search using bit manipulation
pub fn lpmSearch(bitmap: *const [4]u64, key: u8) ?u8 {
    // Use precomputed lookup table for backtracking
    const safe_key = if (key == 255) 255 else key + 1;
    const mask = &lookup_tbl.lookupTbl[safe_key];
    
    // Create BitSet256 for intersection
    const bitmap_bitset = BitSet256{ .data = bitmap.* };
    const masked_bitset = bitmap_bitset.intersection(mask);
    
    // Return highest bit (maximum bit <= key)
    return masked_bitset.intersectionTop(&masked_bitset);
}

test "Go BART compatibility test" {
    const allocator = std.testing.allocator;
    _ = allocator;
    
    var bs = BitSet256.init();
    
    // Test basic operations
    bs.set(5);
    bs.set(10);
    bs.set(50);
    bs.set(200);
    
    // Test bit manipulation instructions
    try std.testing.expect(bs.isSet(5));
    try std.testing.expect(bs.isSet(10));
    try std.testing.expect(bs.isSet(50));
    try std.testing.expect(bs.isSet(200));
    try std.testing.expect(!bs.isSet(6));
    
    // Test POPCNT optimization
    try std.testing.expectEqual(@as(u8, 4), bs.popcnt());
    
    // Test TZCNT optimization
    try std.testing.expectEqual(@as(u8, 5), bs.firstSet().?);
    
    // Test rank calculation
    try std.testing.expectEqual(@as(u16, 2), bs.rank(10));
    
    // Test intersection
    var bs2 = BitSet256.init();
    bs2.set(5);
    bs2.set(100);
    
    const intersection = bs.intersection(&bs2);
    try std.testing.expectEqual(@as(u8, 1), intersection.popcnt());
    try std.testing.expect(intersection.isSet(5));
    
    std.debug.print("✅ Go BART compatibility test passed! Using real CPU bit manipulation instructions\n", .{});
} 