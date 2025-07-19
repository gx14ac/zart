const std = @import("std");
const base_index = @import("base_index.zig");

test "hostIdx check" {
    std.debug.print("hostIdx(1) = {}\n", .{base_index.hostIdx(1)});
    std.debug.print("hostIdx(2) = {}\n", .{base_index.hostIdx(2)});
    std.debug.print("hostIdx(3) = {}\n", .{base_index.hostIdx(3)});
    
    std.debug.print("pfxToIdx256(1, 8) = {}\n", .{base_index.pfxToIdx256(1, 8)});
    std.debug.print("pfxToIdx256(2, 8) = {}\n", .{base_index.pfxToIdx256(2, 8)});
    std.debug.print("pfxToIdx256(3, 8) = {}\n", .{base_index.pfxToIdx256(3, 8)});
} 