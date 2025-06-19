const BitSet256 = @import("bitset256.zig").BitSet256;

// Dynamically generate Go's lookupPrefixRoutes.go content in Zig
pub const pfxRoutesLookupTbl = blk: {
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