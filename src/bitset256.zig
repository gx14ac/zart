const std = @import("std");
const lookup_tbl = @import("lookup_tbl.zig");

// SIMD最適化されたBitSet for managing 0-255 bits
// Implemented with @Vector(4, u64) for SIMD parallelization
// Leverages CPU SIMD instructions for enhanced performance

pub const BitSet256 = struct {
    // SIMD vector: 4つのu64をベクトル化
    data: @Vector(4, u64) align(64),

    // Initialize a new BitSet256
    pub fn init() BitSet256 {
        return BitSet256{ .data = @splat(0) };
    }

    // Set bit to 1
    pub fn set(self: *BitSet256, bit: u8) void {
        const word_idx = bit >> 6;
        const bit_pos = @as(u6, @intCast(bit & 63));
        const mask = @as(u64, 1) << bit_pos;
        
        // SIMD update: 該当するワードのみ更新
        var mask_vec: @Vector(4, u64) = @splat(0);
        mask_vec[word_idx] = mask;
        self.data = self.data | mask_vec;
    }

    // Clear bit
    pub fn clear(self: *BitSet256, bit: u8) void {
        const word_idx = bit >> 6;
        const bit_pos = @as(u6, @intCast(bit & 63));
        const mask = ~(@as(u64, 1) << bit_pos);
        
        // SIMD update: 該当するワードのみ更新
        var mask_vec: @Vector(4, u64) = @splat(~@as(u64, 0));
        mask_vec[word_idx] = mask;
        self.data = self.data & mask_vec;
    }

    // Check if bit is set
    pub fn isSet(self: *const BitSet256, bit: u8) bool {
        const word_idx = bit >> 6;
        const bit_pos = @as(u6, @intCast(bit & 63));
        return (self.data[word_idx] & (@as(u64, 1) << bit_pos)) != 0;
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

    // Return count of set bits (popcount) - SIMD最適化版
    pub fn popcnt(self: *const BitSet256) u8 {
        // 4つのpopcountを並列実行
        const counts: @Vector(4, u8) = @Vector(4, u8){
            @popCount(self.data[0]),
            @popCount(self.data[1]),
            @popCount(self.data[2]),
            @popCount(self.data[3]),
        };
        
        // ベクトルリダクション
        return @reduce(.Add, counts);
    }

    // Return count of set bits up to specified position (rank) - SIMD最適化版
    pub fn rank(self: *const BitSet256, idx: u8) u8 {
        const mask = rankMask[idx].data;
        const masked = self.data & mask;
        
        // 4つのpopcountを並列実行
        const counts: @Vector(4, u8) = @Vector(4, u8){
            @popCount(masked[0]),
            @popCount(masked[1]),
            @popCount(masked[2]),
            @popCount(masked[3]),
        };
        
        // ベクトルリダクション
        return @reduce(.Add, counts);
    }

    // Return whether bitset is empty - SIMD最適化版
    pub fn isEmpty(self: *const BitSet256) bool {
        // ベクトル全体でORリダクション
        const or_result = @reduce(.Or, self.data);
        return or_result == 0;
    }

    // Calculate intersection of two bitsets - SIMD最適化版
    pub fn intersection(self: *const BitSet256, other: *const BitSet256) BitSet256 {
        return BitSet256{ .data = self.data & other.data };
    }

    // Calculate union of two bitsets - SIMD最適化版
    pub fn bitUnion(self: *const BitSet256, other: *const BitSet256) BitSet256 {
        return BitSet256{ .data = self.data | other.data };
    }

    // Return count of set bits in intersection of two bitsets - SIMD最適化版
    pub fn intersectionCardinality(self: *const BitSet256, other: *const BitSet256) u8 {
        const intersection_data = self.data & other.data;
        
        // 4つのpopcountを並列実行
        const counts: @Vector(4, u8) = @Vector(4, u8){
            @popCount(intersection_data[0]),
            @popCount(intersection_data[1]),
            @popCount(intersection_data[2]),
            @popCount(intersection_data[3]),
        };
        
        // ベクトルリダクション
        return @reduce(.Add, counts);
    }

    // Return whether intersection of two bitsets is non-empty - SIMD最適化版
    pub fn intersectsAny(self: *const BitSet256, other: *const BitSet256) bool {
        const intersection_data = self.data & other.data;
        
        // ベクトル全体でORリダクション
        const or_result = @reduce(.Or, intersection_data);
        return or_result != 0;
    }

    // Return highest bit in intersection of two bitsets - SIMD最適化版
    pub fn intersectionTop(self: *const BitSet256, other: *const BitSet256) ?u8 {
        const intersection_data = self.data & other.data;
        
        var i: usize = 4;
        while (i > 0) : (i -= 1) {
            const word = intersection_data[i-1];
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
        var bs = BitSet256{ .data = @splat(0) };
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
    // SIMD版のBitSet256に合わせて更新
    const safe_key = if (key == 255) 255 else key + 1;
    const mask = lookup_tbl.lookupTbl[safe_key]; // Mask with all bits <= key set to 1
    
    // ベクトル演算でマスク適用
    const bitmap_vec: @Vector(4, u64) = @Vector(4, u64){ bitmap[0], bitmap[1], bitmap[2], bitmap[3] };
    const masked_data = bitmap_vec & mask.data;
    const masked = BitSet256{ .data = masked_data };
    
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

test "SIMD performance comparison" {
    @setEvalBranchQuota(10000);
    
    const Timer = std.time.Timer;
    const print = std.debug.print;
    
    print("\n=== SIMD BitSet256 Performance Test ===\n", .{});
    
    // テストデータの準備
    var bs1 = BitSet256.init();
    var bs2 = BitSet256.init();
    
    // ランダムなビットを設定（高密度）
    var i: u16 = 0;
    while (i < 256) : (i += 2) {
        bs1.set(@as(u8, @intCast(i)));
        if (i % 3 == 0) bs2.set(@as(u8, @intCast(i)));
    }
    
    const iterations: u32 = 1_000_000;
    print("Iterations per test: {d}\n\n", .{iterations});
    
    // 1. Intersection performance test
    {
        var timer = Timer.start() catch unreachable;
        var j: u32 = 0;
        while (j < iterations) : (j += 1) {
            const result = bs1.intersection(&bs2);
            std.mem.doNotOptimizeAway(result);
        }
        const elapsed = timer.read();
        const ns_per_op = elapsed / iterations;
        print("Intersection: {d:.2} ns/op ({d:.2} million ops/sec)\n", .{ ns_per_op, 1000.0 / @as(f64, @floatFromInt(ns_per_op)) });
    }
    
    // 2. Union performance test
    {
        var timer = Timer.start() catch unreachable;
        var j: u32 = 0;
        while (j < iterations) : (j += 1) {
            const result = bs1.bitUnion(&bs2);
            std.mem.doNotOptimizeAway(result);
        }
        const elapsed = timer.read();
        const ns_per_op = elapsed / iterations;
        print("Union: {d:.2} ns/op ({d:.2} million ops/sec)\n", .{ ns_per_op, 1000.0 / @as(f64, @floatFromInt(ns_per_op)) });
    }
    
    // 3. IntersectsAny performance test
    {
        var timer = Timer.start() catch unreachable;
        var j: u32 = 0;
        var count: u32 = 0;
        while (j < iterations) : (j += 1) {
            if (bs1.intersectsAny(&bs2)) count += 1;
        }
        const elapsed = timer.read();
        const ns_per_op = elapsed / iterations;
        print("IntersectsAny: {d:.2} ns/op ({d:.2} million ops/sec) [count: {d}]\n", .{ ns_per_op, 1000.0 / @as(f64, @floatFromInt(ns_per_op)), count });
    }
    
    // 4. Popcount performance test
    {
        var timer = Timer.start() catch unreachable;
        var j: u32 = 0;
        var total: u32 = 0;
        while (j < iterations) : (j += 1) {
            total += bs1.popcnt();
        }
        const elapsed = timer.read();
        const ns_per_op = elapsed / iterations;
        print("Popcount: {d:.2} ns/op ({d:.2} million ops/sec) [total: {d}]\n", .{ ns_per_op, 1000.0 / @as(f64, @floatFromInt(ns_per_op)), total });
    }
    
    // 5. IntersectionCardinality performance test
    {
        var timer = Timer.start() catch unreachable;
        var j: u32 = 0;
        var total: u32 = 0;
        while (j < iterations) : (j += 1) {
            total += bs1.intersectionCardinality(&bs2);
        }
        const elapsed = timer.read();
        const ns_per_op = elapsed / iterations;
        print("IntersectionCardinality: {d:.2} ns/op ({d:.2} million ops/sec) [total: {d}]\n", .{ ns_per_op, 1000.0 / @as(f64, @floatFromInt(ns_per_op)), total });
    }
    
    // 6. isEmpty performance test
    {
        var timer = Timer.start() catch unreachable;
        var j: u32 = 0;
        var count: u32 = 0;
        while (j < iterations) : (j += 1) {
            if (!bs1.isEmpty()) count += 1;
        }
        const elapsed = timer.read();
        const ns_per_op = elapsed / iterations;
        print("isEmpty: {d:.2} ns/op ({d:.2} million ops/sec) [count: {d}]\n", .{ ns_per_op, 1000.0 / @as(f64, @floatFromInt(ns_per_op)), count });
    }
    
    print("\n✅ SIMD Performance Test Completed!\n", .{});
}

test "BitSet256 memory layout verification" {
    const bs = BitSet256.init();
    
    // メモリアラインメントの確認
    const alignment = @alignOf(@TypeOf(bs.data));
    try std.testing.expect(alignment >= 32); // SIMD命令のための最小アラインメント
    
    // データサイズの確認
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(@TypeOf(bs.data))); // 4 * 8 = 32 bytes
    
    std.debug.print("✅ SIMD BitSet256 memory layout verified: {d} bytes, {d}-byte aligned\n", .{ @sizeOf(@TypeOf(bs.data)), alignment });
} 