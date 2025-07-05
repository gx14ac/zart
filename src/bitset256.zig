const std = @import("std");
const lookup_tbl = @import("lookup_tbl.zig");

// BitSet for managing 0-255 bits
// Implemented with 4 u64s for cache efficiency
// Leverages CPU bit manipulation instructions

pub const BitSet256 = struct {
    // Aligned to cache line (64 bytes)
    data: [4]u64 align(64),

    // Initialize a new BitSet256
    pub fn init() BitSet256 {
        return BitSet256{ .data = .{0, 0, 0, 0} };
    }

    // Set bit to 1
    pub fn set(self: *BitSet256, bit: u8) void {
        self.data[bit >> 6] |= (@as(u64, 1) << @as(u6, @intCast(bit & 63)));
    }

    // Clear bit
    pub fn clear(self: *BitSet256, bit: u8) void {
        self.data[bit >> 6] &= ~(@as(u64, 1) << @as(u6, @intCast(bit & 63)));
    }

    // Check if bit is set
    pub fn isSet(self: *const BitSet256, bit: u8) bool {
        return (self.data[bit >> 6] & (@as(u64, 1) << @as(u6, @intCast(bit & 63)))) != 0;
    }

    // Return first set bit. Returns null if no bits are set.
    pub fn firstSet(self: *const BitSet256) ?u8 {
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            if (self.data[i] != 0) {
                const trailing = @ctz(self.data[i]);
                return @as(u8, @intCast((i << 6) + trailing));
            }
        }
        return null;
    }

    // Return first set bit after specified bit. Returns null if no bits are set.
    pub fn nextSet(self: *const BitSet256, bit: u8) ?u8 {
        if (bit >= 255) return null;
        var wIdx: usize = bit >> 6;
        const bit_in_word = bit & 63;
        if (bit_in_word < 63) {
            const first: u64 = self.data[wIdx] >> @as(u6, @intCast(bit_in_word + 1));
            if (first != 0) {
                const trailing = @ctz(first);
                return @as(u8, @intCast((wIdx << 6) + bit_in_word + 1 + @as(u8, @intCast(trailing))));
            }
        }
        wIdx += 1;
        while (wIdx < 4) : (wIdx += 1) {
            if (self.data[wIdx] != 0) {
                const trailing = @ctz(self.data[wIdx]);
                return @as(u8, @intCast((wIdx << 6) + trailing));
            }
        }
        return null;
    }

    // Return count of set bits (popcount)
    pub fn popcnt(self: *const BitSet256) u8 {
        var cnt: u8 = 0;
        cnt += @popCount(self.data[0]);
        cnt += @popCount(self.data[1]);
        cnt += @popCount(self.data[2]);
        cnt += @popCount(self.data[3]);
        return cnt;
    }

    // Return count of set bits up to specified position (rank)
    pub fn rank(self: *const BitSet256, idx: u8) u8 {
        var rnk: u8 = 0;
        rnk += @popCount(self.data[0] & rankMask[idx].data[0]);
        rnk += @popCount(self.data[1] & rankMask[idx].data[1]);
        rnk += @popCount(self.data[2] & rankMask[idx].data[2]);
        rnk += @popCount(self.data[3] & rankMask[idx].data[3]);
        return rnk;
    }

    // Return whether bitset is empty
    pub fn isEmpty(self: *const BitSet256) bool {
        return (self.data[0] | self.data[1] | self.data[2] | self.data[3]) == 0;
    }

    // Calculate intersection of two bitsets
    pub fn intersection(self: *const BitSet256, other: *const BitSet256) BitSet256 {
        var bs = BitSet256{ .data = .{0,0,0,0} };
        bs.data[0] = self.data[0] & other.data[0];
        bs.data[1] = self.data[1] & other.data[1];
        bs.data[2] = self.data[2] & other.data[2];
        bs.data[3] = self.data[3] & other.data[3];
        return bs;
    }

    // Calculate union of two bitsets
    pub fn bitUnion(self: *const BitSet256, other: *const BitSet256) BitSet256 {
        var bs = BitSet256{ .data = .{0,0,0,0} };
        bs.data[0] = self.data[0] | other.data[0];
        bs.data[1] = self.data[1] | other.data[1];
        bs.data[2] = self.data[2] | other.data[2];
        bs.data[3] = self.data[3] | other.data[3];
        return bs;
    }

    // Return count of set bits in intersection of two bitsets
    pub fn intersectionCardinality(self: *const BitSet256, other: *const BitSet256) u8 {
        var cnt: u8 = 0;
        cnt += @popCount(self.data[0] & other.data[0]);
        cnt += @popCount(self.data[1] & other.data[1]);
        cnt += @popCount(self.data[2] & other.data[2]);
        cnt += @popCount(self.data[3] & other.data[3]);
        return cnt;
    }

    // Return whether intersection of two bitsets is non-empty
    pub fn intersectsAny(self: *const BitSet256, other: *const BitSet256) bool {
        // 演算結果を一時変数に代入してランタイム値として扱う
        const result0 = self.data[0] & other.data[0];
        const result1 = self.data[1] & other.data[1];
        const result2 = self.data[2] & other.data[2];
        const result3 = self.data[3] & other.data[3];
        
        // 比較結果も一時変数に代入
        const check0 = result0 != 0;
        const check1 = result1 != 0;
        const check2 = result2 != 0;
        const check3 = result3 != 0;
        
        return check0 or check1 or check2 or check3;
    }

    // Return highest bit in intersection of two bitsets. Returns null if intersection is empty.
    pub fn intersectionTop(self: *const BitSet256, other: *const BitSet256) ?u8 {
        var i: usize = 4;
        while (i > 0) : (i -= 1) {
            const word = self.data[i-1] & other.data[i-1];
            if (word != 0) {
                const lz = @clz(word);
                const bit_pos = @as(u8, @intCast((i-1))) << 6;
                const bit_offset = @as(u8, @intCast(63 - lz));
                return bit_pos + bit_offset;
            }
        }
        return null;
    }

    // Return set bits as slice. buf is a buffer of 256 u8s.
    pub fn asSlice(self: *const BitSet256, buf: *[256]u8) []u8 {
        var size: usize = 0;
        var wIdx: usize = 0;
        while (wIdx < 4) : (wIdx += 1) {
            var word = self.data[wIdx];
            while (word != 0) : (size += 1) {
                const trailing = @ctz(word);
                // wIdx: 0-3, trailing: 0-63, 最大値: 3*64+63 = 255
                buf[size] = @as(u8, @intCast((wIdx << 6) + trailing));
                word &= (word - 1); // Clear least significant bit
            }
        }
        return buf[0..size];
    }

    // Return set bits as slice. Allocates buffer internally.
    pub fn all(self: *const BitSet256) []u8 {
        var buf: [256]u8 = undefined;
        return self.asSlice(&buf);
    }

    // Return debug string
    pub fn string(self: *const BitSet256) []const u8 {
        var buf: [256]u8 = undefined;
        const slice = self.asSlice(&buf);
        var i: usize = 0;
        var j: usize = 0;
        while (i < slice.len) : (i += 1) {
            j += std.fmt.bufPrint(buf[j..], "{d} ", .{ slice[i] }) catch break;
        }
        return buf[0..j];
    }

    // Create BitSet256 from slice of bits to set
    pub fn fromSlice(bits: []const u8) BitSet256 {
        var bs = BitSet256.init();
        for (bits) |bit| {
            bs.set(bit);
        }
        return bs;
    }
};

// rankMask is an array of BitSet256 with bits 0-255 set.
// Example: rankMask[7] is a BitSet256 with bits 0-7 set.
pub const rankMask = blk: {
    @setEvalBranchQuota(100000);
    var arr: [256]BitSet256 = undefined;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        var bs = BitSet256{ .data = .{0,0,0,0} };
        var j: usize = 0;
        while (j <= i) : (j += 1) {
            bs.set(@as(u8, j));
        }
        arr[i] = bs;
    }
    break :blk arr;
};

/// LPM (Longest Prefix Match) search: return maximum bit position <= key in bitmap (null if none)
pub fn lpmSearch(bitmap: *const [4]u64, key: u8) ?u8 {
    // Limit key + 1 to not exceed 256
    const safe_key = if (key == 255) 255 else key + 1;
    const mask = lookup_tbl.lookupTbl[safe_key]; // Mask with all bits <= key set to 1
    var masked = BitSet256{ .data = .{
        bitmap[0] & mask.data[0],
        bitmap[1] & mask.data[1],
        bitmap[2] & mask.data[2],
        bitmap[3] & mask.data[3],
    }};
    // Return highest bit (maximum bit <= key)
    return masked.intersectionTop(&masked);
}

test "BitSet256 basic operations" {
    @setEvalBranchQuota(10000);
    
    var bs = BitSet256.init();
    
    // Test set and isSet
    bs.set(0);
    try std.testing.expect(bs.isSet(0));
    try std.testing.expect(!bs.isSet(1));
    
    bs.set(63);
    try std.testing.expect(bs.isSet(63));
    
    bs.set(64);
    try std.testing.expect(bs.isSet(64));
    
    bs.set(255);
    try std.testing.expect(bs.isSet(255));
    
    // Test clear
    bs.clear(0);
    try std.testing.expect(!bs.isSet(0));
    try std.testing.expect(bs.isSet(63));
    try std.testing.expect(bs.isSet(64));
    try std.testing.expect(bs.isSet(255));
    
    // Test rank
    try std.testing.expectEqual(@as(usize, 0), bs.rank(0));
    try std.testing.expectEqual(@as(usize, 1), bs.rank(63));
    try std.testing.expectEqual(@as(usize, 2), bs.rank(64));
    try std.testing.expectEqual(@as(usize, 3), bs.rank(255));
    
    // Test nextSet
    try std.testing.expectEqual(@as(u8, 63), bs.nextSet(0).?);
    try std.testing.expectEqual(@as(u8, 64), bs.nextSet(63).?);
    try std.testing.expectEqual(@as(u8, 255), bs.nextSet(64).?);
    try std.testing.expect(bs.nextSet(255) == null);
} 