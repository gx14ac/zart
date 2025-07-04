//! BackTrackingBitset lookup table for LPM
//! This implements the backtracking sequence in the complete binary tree
//! of the prefixes as bitstring.

const std = @import("std");
const BitSet256 = @import("bitset256.zig").BitSet256;

/// BackTrackingBitset returns the backtracking bitset for the given index
/// This allows a one shot bitset intersection algorithm instead of
/// a sequence of single bitset tests.
pub fn backTrackingBitset(idx: usize) BitSet256 {
    var bs = BitSet256.init();
    var i: usize = idx & 511; // &511 is BCE
    
    // Generate backtracking sequence: for idx := 1; idx > 0; idx >>= 1 { b.Set(idx) }
    while (i > 0) : (i >>= 1) {
        // 256-511の範囲を0-255にマッピング
        const bit: u8 = if (i > 255) @as(u8, @intCast(i - 256)) else @as(u8, @intCast(i));
        bs.set(bit);
    }
    
    return bs;
}

/// Lookup table for backtracking bitsets
/// Each entry contains the backtracking sequence for that index
pub const lookupTbl = blk: {
    @setEvalBranchQuota(100000);
    var arr: [512]BitSet256 = undefined;
    var i: usize = 0;
    while (i < 512) : (i += 1) {
        arr[i] = backTrackingBitset(i);
    }
    break :blk arr;
};

test "backTrackingBitset basic" {
    var bs1 = backTrackingBitset(1);
    try std.testing.expect(bs1.isSet(1));
    try std.testing.expect(!bs1.isSet(2));
    
    var bs2 = backTrackingBitset(2);
    try std.testing.expect(bs2.isSet(1));
    try std.testing.expect(bs2.isSet(2));
    try std.testing.expect(!bs2.isSet(3));
    
    var bs3 = backTrackingBitset(3);
    try std.testing.expect(bs3.isSet(1));
    try std.testing.expect(bs3.isSet(3));
    try std.testing.expect(!bs3.isSet(2));
}

test "lookupTbl basic" {
    // 基本的なルックアップテーブルのテスト
    try std.testing.expect(lookupTbl[0].isEmpty());
    try std.testing.expect(lookupTbl[1].isSet(1));
    try std.testing.expect(lookupTbl[2].isSet(1));
    try std.testing.expect(lookupTbl[2].isSet(2));
    try std.testing.expect(lookupTbl[3].isSet(1));
    try std.testing.expect(lookupTbl[3].isSet(3));
    
    // ホストアドレスのテスト（256-511）
    try std.testing.expect(lookupTbl[256].isSet(0)); // 256 -> 0
    try std.testing.expect(lookupTbl[257].isSet(1)); // 257 -> 1
    try std.testing.expect(lookupTbl[511].isSet(255)); // 511 -> 255
}

test "lookupTbl consistency" {
    // 動的生成とルックアップテーブルの一貫性テスト（サンプルテスト）
    const test_indices = [_]usize{ 0, 1, 2, 3, 10, 100, 255, 256, 257, 511 };
    for (test_indices) |i| {
        const dynamic = backTrackingBitset(i);
        const lookup = lookupTbl[i];
        
        // すべてのビットが一致することを確認
        var bit: u8 = 0;
        while (true) {
            try std.testing.expectEqual(dynamic.isSet(bit), lookup.isSet(bit));
            if (bit == 255) break;
            bit += 1;
        }
    }
} 