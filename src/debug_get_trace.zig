const std = @import("std");
const print = std.debug.print;
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;
const base_index = @import("base_index.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== Get Method Trace ===\n", .{});
    
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    // Insert 1.2.3.4/32 -> 1234
    const addr = IPAddr{ .v4 = .{ 1, 2, 3, 4 } };
    const prefix = Prefix.init(&addr, 32).masked();
    print("\nInserting 1.2.3.4/32 -> 1234\n", .{});
    table.insert(&prefix, 1234);
    
    // Trace the get operation
    print("\nTracing get(1.2.3.4/32):\n", .{});
    const octets = addr.asSlice();
    print("  octets: [{}, {}, {}, {}]\n", .{ octets[0], octets[1], octets[2], octets[3] });
    print("  bits: 32\n", .{});
    
    const max_depth_info = base_index.maxDepthAndLastBits(32);
    print("  max_depth: {}\n", .{max_depth_info.max_depth});
    print("  last_bits: {}\n", .{max_depth_info.last_bits});
    
    print("\nLoop iteration analysis:\n", .{});
    print("  for (octets, 0..) |octet, depth| {{\n", .{});
    print("    depth=0, octet=1: depth(0) vs max_depth(4) - continue\n", .{});
    print("    depth=1, octet=2: depth(1) vs max_depth(4) - continue\n", .{});
    print("    depth=2, octet=3: depth(2) vs max_depth(4) - continue\n", .{});
    print("    depth=3, octet=4: depth(3) vs max_depth(4) - continue\n", .{});
    print("  }}\n", .{});
    print("  Loop ends at depth=4, but octets only has 4 elements (0-3)\n", .{});
    print("  So the loop never reaches depth=4!\n", .{});
    
    print("\n=== The Problem ===\n", .{});
    print("For /32 prefixes:\n", .{});
    print("- max_depth=4 (from bits >> 3 = 32 >> 3 = 4)\n", .{});
    print("- But IPv4 octets array has indices 0-3\n", .{});
    print("- The loop ends before checking depth==max_depth\n", .{});
    print("- So /32 prefixes are stored as leafNodes\n", .{});
    print("- But get() doesn't reach the leafNode check!\n", .{});
    
    // Test the actual result
    const result = table.get(&prefix);
    print("\nActual result: {?}\n", .{result});
} 