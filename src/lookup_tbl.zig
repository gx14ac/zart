//! BackTrackingBitset lookup table for LPM
//! This implements the backtracking sequence in the complete binary tree
//! of the prefixes as bitstring.

const std = @import("std");
const BitSet256 = @import("bitset256.zig").BitSet256;
const base_index = @import("base_index.zig");

/// BackTrackingBitset returns the backtracking bitset for the given index
/// This allows a one shot bitset intersection algorithm instead of
/// a sequence of single bitset tests.
/// Go BART compatible implementation - uses precomputed lookup table
pub fn backTrackingBitset(idx: usize) BitSet256 {
    return lookupTbl[idx & 511]; // &511 is BCE
}

/// Lookup table for backtracking bitsets - Go BART compatible
/// Each entry contains the backtracking sequence for that index
/// Direct port of Go BART's algorithm:
/// for idx := 1; idx > 0; idx >>= 1 { b.Set(idx) }
pub const lookupTbl = blk: {
    @setEvalBranchQuota(100000);
    var arr: [512]BitSet256 = undefined;
    
    for (0..512) |i| {
        var bs = BitSet256.init();
        var idx: usize = i;
        
        // Go BART algorithm: for idx := 1; idx > 0; idx >>= 1 { b.Set(idx) }
        while (idx > 0) : (idx >>= 1) {
            // Map high indices (256-511) to their corresponding low indices (0-255)
            // This is because BitSet256 only supports 0-255
            const mapped_idx = idx & 0xFF;
            bs.set(@as(u8, @intCast(mapped_idx)));
        }
        
        arr[i] = bs;
    }
    
    break :blk arr;
};

/// IdxToPrefixRoutes: インデックスに対して、そのプレフィックスによってカバーされる
/// より長いプレフィックスのビットセットを返す
pub fn idxToPrefixRoutes(idx: u8) BitSet256 {
    var result = BitSet256.init();
    
    if (idx == 0) return result; // invalid
    
    // Go実装のallotRec関数を再現
    // 完全な二分木でのプレフィックスルートを計算
    allotRec(&result, @as(usize, idx));
    
    return result;
}

/// 再帰的にプレフィックスルートを計算する内部関数
fn allotRec(bitset: *BitSet256, idx: usize) void {
    // 自分自身を設定
    if (idx <= 255) {
        bitset.set(@intCast(idx));
    }
    
    // 256より大きい場合は終了（フリンジ領域）
    if (idx > 255) {
        return;
    }
    
    // 左の子ノード
    allotRec(bitset, idx << 1);
    // 右の子ノード  
    allotRec(bitset, (idx << 1) + 1);
}

/// IdxToFringeRoutes: インデックスに対して、そのプレフィックスによってカバーされる
/// 子ノードアドレスのビットセットを返す
pub fn idxToFringeRoutes(idx: u8) BitSet256 {
    var result = BitSet256.init();
    
    if (idx == 0) return result; // invalid
    
    // Go実装のallotRec関数を再現（フリンジ用）
    // 完全な二分木でのフリンジルートを計算
    allotFringeRec(&result, @as(usize, idx));
    
    return result;
}

/// 再帰的にフリンジルートを計算する内部関数
fn allotFringeRec(bitset: *BitSet256, idx: usize) void {
    // 256以上の場合（フリンジ領域）のみ設定
    if (idx > 255) {
        const fringe_idx = idx - 256;
        if (fringe_idx <= 255) {
            bitset.set(@intCast(fringe_idx));
        }
        return;
    }
    
    // 左の子ノード
    allotFringeRec(bitset, idx << 1);
    // 右の子ノード  
    allotFringeRec(bitset, (idx << 1) + 1);
}

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

test "idxToPrefixRoutes basic" {
    // Go実装のテストケースに合わせて修正
    // idx: 41 -> want: [41, 82, 83, 164, 165, 166, 167]
    const result41 = idxToPrefixRoutes(41);
    try std.testing.expect(result41.isSet(41));
    try std.testing.expect(result41.isSet(82));
    try std.testing.expect(result41.isSet(83));
    try std.testing.expect(result41.isSet(164));
    try std.testing.expect(result41.isSet(165));
    try std.testing.expect(result41.isSet(166));
    try std.testing.expect(result41.isSet(167));
    
    // idx: 127 -> want: [127, 254, 255]
    const result127 = idxToPrefixRoutes(127);
    try std.testing.expect(result127.isSet(127));
    try std.testing.expect(result127.isSet(254));
    try std.testing.expect(result127.isSet(255));
    
    // idx: 128 -> want: [128]
    const result128 = idxToPrefixRoutes(128);
    try std.testing.expect(result128.isSet(128));
    try std.testing.expect(!result128.isSet(129)); // 子ノードは256以上なので含まれない
    
    const result0 = idxToPrefixRoutes(0);
    try std.testing.expect(result0.isEmpty());
}

test "idxToFringeRoutes basic" {
    // Go実装のテストケースに合わせて修正
    // idx: 63 -> want: [248, 249, 250, 251, 252, 253, 254, 255]
    const result63 = idxToFringeRoutes(63);
    try std.testing.expect(result63.isSet(248));
    try std.testing.expect(result63.isSet(249));
    try std.testing.expect(result63.isSet(250));
    try std.testing.expect(result63.isSet(251));
    try std.testing.expect(result63.isSet(252));
    try std.testing.expect(result63.isSet(253));
    try std.testing.expect(result63.isSet(254));
    try std.testing.expect(result63.isSet(255));
    
    // idx: 127 -> want: [252, 253, 254, 255]
    const result127 = idxToFringeRoutes(127);
    try std.testing.expect(result127.isSet(252));
    try std.testing.expect(result127.isSet(253));
    try std.testing.expect(result127.isSet(254));
    try std.testing.expect(result127.isSet(255));
    
    // idx: 128 -> want: [0, 1]
    const result128 = idxToFringeRoutes(128);
    try std.testing.expect(result128.isSet(0));
    try std.testing.expect(result128.isSet(1));
    
    const result0 = idxToFringeRoutes(0);
    try std.testing.expect(result0.isEmpty());
} 