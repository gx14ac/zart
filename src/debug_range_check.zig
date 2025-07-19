const std = @import("std");
const print = std.debug.print;
const base_index = @import("base_index.zig");

pub fn main() !void {
    print("=== ZART Range Check Analysis ===\n", .{});
    
    print("\n=== Index to Range Mapping ===\n", .{});
    
    // Check the ranges for our critical indices
    const indices = [_]u8{ 128, 129 };
    
    for (indices) |idx| {
        print("Index {} analysis:\n", .{idx});
        
        // Get the prefix info
        const pfx_info = base_index.idxToPfx256(idx) catch {
            print("  ERROR: Failed to decode index {}\n", .{idx});
            continue;
        };
        print("  idxToPfx256({}) = octet:{}, pfx_len:{}\n", .{ idx, pfx_info.octet, pfx_info.pfx_len });
        
        // Get the range
        const range = base_index.idxToRange256(idx) catch {
            print("  ERROR: Failed to get range for index {}\n", .{idx});
            continue;
        };
        print("  idxToRange256({}) = first:{}, last:{}\n", .{ idx, range.first, range.last });
        
        // Test which octets fall within this range
        print("  Octets in range [{}..{}]: ", .{ range.first, range.last });
        for (0..6) |octet| {
            if (octet >= range.first and octet <= range.last) {
                print("{} ", .{octet});
            }
        }
        print("\n", .{});
    }
    
    print("\n=== Critical Test Cases ===\n", .{});
    
    // Test the specific cases that are failing
    const test_cases = [_]struct { idx: u8, octet: u8, should_match: bool }{
        .{ .idx = 128, .octet = 0, .should_match = false }, // Go BART: false, ZART: true
        .{ .idx = 128, .octet = 1, .should_match = true },  // Go BART: true, ZART: true
        .{ .idx = 129, .octet = 2, .should_match = true },  // Go BART: true, ZART: true
        .{ .idx = 129, .octet = 3, .should_match = false }, // Go BART: false, ZART: true
    };
    
    for (test_cases) |case| {
        print("Test: Index {} with octet {} (expected: {})\n", .{ case.idx, case.octet, case.should_match });
        
        const range = base_index.idxToRange256(case.idx) catch {
            print("  ERROR: Failed to get range for index {}\n", .{case.idx});
            continue;
        };
        
        const actual_match = case.octet >= range.first and case.octet <= range.last;
        print("  Range [{}..{}], octet {}, match: {}\n", .{ range.first, range.last, case.octet, actual_match });
        
        if (actual_match == case.should_match) {
            print("  ✅ Correct result\n", .{});
        } else {
            print("  ❌ Wrong result! Expected {}, got {}\n", .{ case.should_match, actual_match });
        }
    }
    
    print("\n=== netMask Function Test ===\n", .{});
    
    // Test the netMask function for different bit counts
    for (0..9) |bits| {
        const mask = base_index.netMask(@intCast(bits));
        print("netMask({}) = 0b{b:0>8} ({})\n", .{ bits, mask, mask });
    }
    
    print("\n=== Manual Range Calculation ===\n", .{});
    
    // Manually calculate what the ranges should be
    print("Manual calculation for index 128:\n", .{});
    const pfx128 = base_index.idxToPfx256(128) catch return;
    print("  octet: {}, pfx_len: {}\n", .{ pfx128.octet, pfx128.pfx_len });
    const mask128 = base_index.netMask(pfx128.pfx_len);
    print("  mask: 0b{b:0>8} ({})\n", .{ mask128, mask128 });
    const last128 = pfx128.octet | ~mask128;
    print("  first: {}, last: {} | ~{} = {}\n", .{ pfx128.octet, pfx128.octet, mask128, last128 });
    
    print("Manual calculation for index 129:\n", .{});
    const pfx129 = base_index.idxToPfx256(129) catch return;
    print("  octet: {}, pfx_len: {}\n", .{ pfx129.octet, pfx129.pfx_len });
    const mask129 = base_index.netMask(pfx129.pfx_len);
    print("  mask: 0b{b:0>8} ({})\n", .{ mask129, mask129 });
    const last129 = pfx129.octet | ~mask129;
    print("  first: {}, last: {} | ~{} = {}\n", .{ pfx129.octet, pfx129.octet, mask129, last129 });
} 