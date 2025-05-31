const std = @import("std");
const BitSet256 = @import("bitset256.zig").BitSet256;

// Goのlookuptbl.goの内容をZigで動的生成
pub const lookupTbl = blk: {
    // comptime評価の分岐上限を引き上げる
    @setEvalBranchQuota(10000);
    
    var arr: [256]BitSet256 = undefined;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        // iビット目までのマスクを直接計算
        var data: [4]u64 = .{0, 0, 0, 0};
        const chunk = @min(i >> 6, 3); // 最大でも3（4要素の配列の範囲内）に制限
        const bit = i & 0x3F;
        var j: usize = 0;
        while (j < chunk) : (j += 1) {
            data[j] = ~@as(u64, 0);
        }
        if (bit > 0 and chunk < 4) {
            data[chunk] = (@as(u64, 1) << @as(u6, @intCast(bit))) - 1;
        }
        arr[i] = BitSet256{ .data = data };
    }
    break :blk arr;
}; 