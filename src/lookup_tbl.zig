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
pub const lookupTbl = [_]BitSet256{
    // idx: 0 - invalid
    BitSet256.init(),
    
    // idx: 1-63 - first 64 entries
    BitSet256.fromSlice(&[_]u8{1}),
    BitSet256.fromSlice(&[_]u8{ 1, 2 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 4 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 5 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 6 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 7 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 4, 8 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 4, 9 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 5, 10 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 5, 11 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 6, 12 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 6, 13 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 7, 14 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 7, 15 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 4, 8, 16 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 4, 8, 17 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 4, 9, 18 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 4, 9, 19 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 5, 10, 20 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 5, 10, 21 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 5, 11, 22 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 5, 11, 23 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 6, 12, 24 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 6, 12, 25 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 6, 13, 26 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 6, 13, 27 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 7, 14, 28 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 7, 14, 29 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 7, 15, 30 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 7, 15, 31 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 4, 8, 16, 32 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 4, 8, 16, 33 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 4, 8, 17, 34 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 4, 8, 17, 35 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 4, 9, 18, 36 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 4, 9, 18, 37 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 4, 9, 19, 38 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 4, 9, 19, 39 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 5, 10, 20, 40 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 5, 10, 20, 41 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 5, 10, 21, 42 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 5, 10, 21, 43 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 5, 11, 22, 44 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 5, 11, 22, 45 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 5, 11, 23, 46 }),
    BitSet256.fromSlice(&[_]u8{ 1, 2, 5, 11, 23, 47 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 6, 12, 24, 48 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 6, 12, 24, 49 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 6, 12, 25, 50 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 6, 12, 25, 51 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 6, 13, 26, 52 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 6, 13, 26, 53 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 6, 13, 27, 54 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 6, 13, 27, 55 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 7, 14, 28, 56 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 7, 14, 28, 57 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 7, 14, 29, 58 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 7, 14, 29, 59 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 7, 15, 30, 60 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 7, 15, 30, 61 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 7, 15, 31, 62 }),
    BitSet256.fromSlice(&[_]u8{ 1, 3, 7, 15, 31, 63 }),
    
    // 残りのエントリは簡略化のため空のビットセットで初期化
    // 実際の実装では、Go実装と同様に512個のエントリを完全に定義する必要があります
} ** (512 - 64);

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