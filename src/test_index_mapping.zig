const std = @import("std");
const print = std.debug.print;
const base_index = @import("base_index.zig");

test "Index Mapping Analysis" {
    print("=== Index Mapping Analysis ===\n", .{});
    
    // Test critical indices
    const test_indices = [_]u8{ 4, 128, 129, 130 };
    
    for (test_indices) |idx| {
        print("Index {}: ", .{idx});
        
        if (base_index.idxToPfx256(idx)) |result| {
            print("octet={}, pfx_len={}\n", .{ result.octet, result.pfx_len });
            
            // Calculate what pfxLen256 would return at depth 3
            if (base_index.pfxLen256(3, idx)) |pfx_len_result| {
                print("  → pfxLen256(depth=3, idx={}) = {}\n", .{ idx, pfx_len_result });
            } else |err| {
                print("  → pfxLen256 error: {}\n", .{err});
            }
        } else |err| {
            print("error: {}\n", .{err});
        }
    }
    
    print("\n=== Expected Mappings ===\n", .{});
    print("Index 4:   192.168.0.0/26  → should map to octet=0, pfx_len=2\n", .{});
    print("Index 128: 192.168.0.1/32  → should map to octet=1, pfx_len=8\n", .{});
    print("Index 129: 192.168.0.2/32  → should map to octet=2, pfx_len=8\n", .{});
    
    print("\n=== Reverse Mapping Test ===\n", .{});
    
    // Test pfxToIdx256 for our expected prefixes
    const pfx_128 = base_index.pfxToIdx256(1, 8);
    const pfx_129 = base_index.pfxToIdx256(2, 8); 
    const pfx_4 = base_index.pfxToIdx256(0, 2);
    
    print("pfxToIdx256(1, 8) = {} (expected: 128)\n", .{pfx_128});
    print("pfxToIdx256(2, 8) = {} (expected: 129)\n", .{pfx_129});
    print("pfxToIdx256(0, 2) = {} (expected: 4)\n", .{pfx_4});
} 