const std = @import("std");
const base_index = @import("base_index.zig");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("=== IdxToPfx256 Analysis ===\n\n", .{});

    // Test the same indices that appear in our problematic case
    const test_indices = [_]u8{ 128, 129 };

    for (test_indices) |idx| {
        const idx_info = try base_index.idxToPfx256(idx);
        try stdout.print("ZART idxToPfx256({}):\n", .{idx});
        try stdout.print("  octet: {}\n", .{idx_info.octet});
        try stdout.print("  pfx_len: {}\n", .{idx_info.pfx_len});
        
        // Calculate the range this represents
        const range = try base_index.idxToRange256(idx);
        try stdout.print("  range: {}-{}\n", .{ range.first, range.last });
        
        // Check if octet 3 falls within this range
        const contains_3 = (3 >= range.first and 3 <= range.last);
        try stdout.print("  contains octet 3: {}\n\n", .{contains_3});
    }

    // According to Go BART debug output:
    try stdout.print("Go BART behavior (from debug output):\n", .{});
    try stdout.print("  idx=128: octet=0, pfxLen=8 (exact match for 0)\n", .{});
    try stdout.print("  idx=129: octet=2, pfxLen=7 (range 2-3)\n\n", .{});

    // The key insight
    try stdout.print("=== Key Insight ===\n", .{});
    try stdout.print("When Go BART stores 192.168.0.1/32 at index 128,\n", .{});
    try stdout.print("it's storing it with octet=0, not octet=1!\n\n", .{});
    
    try stdout.print("This suggests Go BART might be using a different\n", .{});
    try stdout.print("storage strategy or transformation that we're missing.\n", .{});
} 