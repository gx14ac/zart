const std = @import("std");
const BitSet256 = @import("bitset256.zig").BitSet256;

// Dynamically generate Go's lookuptbl.go content in Zig
pub const lookupTbl = blk: {
    // Increase comptime evaluation branch limit
    @setEvalBranchQuota(10000);
    
    var arr: [256]BitSet256 = undefined;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        // Directly calculate mask up to i-th bit
        var data: [4]u64 = .{0, 0, 0, 0};
        const chunk = @min(i >> 6, 3); // Limit to maximum 3 (within 4-element array range)
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