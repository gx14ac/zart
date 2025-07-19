const std = @import("std");
const print = std.debug.print;
const base_index = @import("base_index.zig");

pub fn main() !void {
    print("=== ZART pfx_len Analysis ===\n", .{});
    
    print("\n=== Index Analysis ===\n", .{});
    
    // Check the pfx_len for our critical indices
    const indices = [_]u8{ 128, 129 };
    
    for (indices) |idx| {
        print("Index {} analysis:\n", .{idx});
        
        const pfx_info = base_index.idxToPfx256(idx) catch {
            print("  ERROR: Failed to decode index {}\n", .{idx});
            continue;
        };
        print("  idxToPfx256({}) = octet:{}, pfx_len:{}\n", .{ idx, pfx_info.octet, pfx_info.pfx_len });
        
        // Check if this pfx_len equals 8 (which we're using for exact match)
        if (pfx_info.pfx_len == 8) {
            print("  → This index requires EXACT match (pfx_len == 8)\n", .{});
            print("    Only octet {} should match\n", .{pfx_info.octet});
        } else {
            print("  → This index uses RANGE match (pfx_len != 8)\n", .{});
            const range = base_index.idxToRange256(idx) catch {
                print("    ERROR: Failed to get range\n", .{});
                continue;
            };
            print("    Range: [{}..{}]\n", .{ range.first, range.last });
        }
    }
    
    print("\n=== Test Our Logic ===\n", .{});
    
    // Test our matching logic for the problematic cases
    const test_cases = [_]struct { idx: u8, octet: u8, expected_go_bart: bool }{
        .{ .idx = 128, .octet = 0, .expected_go_bart = false },
        .{ .idx = 128, .octet = 1, .expected_go_bart = true },
        .{ .idx = 129, .octet = 2, .expected_go_bart = true },
        .{ .idx = 129, .octet = 3, .expected_go_bart = false },
    };
    
    for (test_cases) |case| {
        print("Test: Index {} with octet {} (Go BART should return: {})\n", .{ case.idx, case.octet, case.expected_go_bart });
        
        const idx_info = base_index.idxToPfx256(case.idx) catch {
            print("  ERROR: Failed to decode index\n", .{});
            continue;
        };
        
        print("  Index info: octet={}, pfx_len={}\n", .{ idx_info.octet, idx_info.pfx_len });
        
        // Apply our matching logic
        const matches = if (idx_info.pfx_len == 8) 
            case.octet == idx_info.octet
        else blk: {
            const range = base_index.idxToRange256(case.idx) catch {
                print("    ERROR: Failed to get range\n", .{});
                break :blk false;
            };
            break :blk (case.octet >= range.first and case.octet <= range.last);
        };
        
        print("  Our logic result: {}\n", .{matches});
        
        if (matches == case.expected_go_bart) {
            print("  ✅ Our logic matches Go BART expectation\n", .{});
        } else {
            print("  ❌ Our logic is WRONG! Expected {}, got {}\n", .{ case.expected_go_bart, matches });
        }
    }
    
    print("\n=== Key Question ===\n", .{});
    print("If our logic is correct but ZART still returns wrong results,\n", .{});
    print("then there might be an issue with:\n", .{});
    print("1. How we store prefixes in the tree\n", .{});
    print("2. The depths at which prefixes are stored\n", .{});
    print("3. The octets being compared at different depths\n", .{});
} 