const std = @import("std");
const print = std.debug.print;
const node = @import("node.zig");
const IPAddr = node.IPAddr;
const Prefix = node.Prefix;

pub fn main() !void {
    print("=== Prefix Containment Check Debug ===\n", .{});
    
    // Create test addresses and prefixes
    const addr_192_168_0_3 = IPAddr{ .v4 = .{ 192, 168, 0, 3 } };
    const addr_192_168_0_2 = IPAddr{ .v4 = .{ 192, 168, 0, 2 } };
    const addr_192_168_0_1 = IPAddr{ .v4 = .{ 192, 168, 0, 1 } };
    const addr_192_168_0_0 = IPAddr{ .v4 = .{ 192, 168, 0, 0 } };
    
    // Test prefixes
    const pfx_192_168_0_1_32 = Prefix.init(&addr_192_168_0_1, 32);
    const pfx_192_168_0_2_32 = Prefix.init(&addr_192_168_0_2, 32);
    const pfx_192_168_0_0_26 = Prefix.init(&addr_192_168_0_0, 26);
    
    print("Testing containment:\n", .{});
    print("192.168.0.1/32 contains 192.168.0.3: {}\n", .{pfx_192_168_0_1_32.containsAddr(addr_192_168_0_3)});
    print("192.168.0.2/32 contains 192.168.0.3: {}\n", .{pfx_192_168_0_2_32.containsAddr(addr_192_168_0_3)});
    print("192.168.0.0/26 contains 192.168.0.3: {}\n", .{pfx_192_168_0_0_26.containsAddr(addr_192_168_0_3)});
    
    print("\nTesting prefix ranges:\n", .{});
    print("192.168.0.1/32 range: {}\n", .{pfx_192_168_0_1_32});
    print("192.168.0.2/32 range: {}\n", .{pfx_192_168_0_2_32});
    print("192.168.0.0/26 range: {}\n", .{pfx_192_168_0_0_26});
    
    // Test masked addresses
    print("\nTesting masked addresses:\n", .{});
    const masked_addr_3_32 = addr_192_168_0_3.masked(32);
    const masked_addr_3_26 = addr_192_168_0_3.masked(26);
    print("192.168.0.3 masked to /32: {}\n", .{masked_addr_3_32});
    print("192.168.0.3 masked to /26: {}\n", .{masked_addr_3_26});
    
    // Test specific bit operations
    print("\nTesting specific bit operations:\n", .{});
    const octets_3 = addr_192_168_0_3.asSlice();
    const octets_2 = addr_192_168_0_2.asSlice();
    const octets_0 = addr_192_168_0_0.asSlice();
    
    print("192.168.0.3 octets: [{}, {}, {}, {}]\n", .{octets_3[0], octets_3[1], octets_3[2], octets_3[3]});
    print("192.168.0.2 octets: [{}, {}, {}, {}]\n", .{octets_2[0], octets_2[1], octets_2[2], octets_2[3]});
    print("192.168.0.0 octets: [{}, {}, {}, {}]\n", .{octets_0[0], octets_0[1], octets_0[2], octets_0[3]});
    
    print("\n=== 192.168.0.0/26 Range Analysis ===\n", .{});
    print("192.168.0.0/26 should contain 192.168.0.0 to 192.168.0.63\n", .{});
    print("192.168.0.3 is in range: {}\n", .{3 <= 63});
    print("192.168.0.2 is in range: {}\n", .{2 <= 63});
    print("192.168.0.1 is in range: {}\n", .{1 <= 63});
    
    print("\n=== Expected Results ===\n", .{});
    print("192.168.0.1/32 should contain 192.168.0.3: false (only contains 192.168.0.1)\n", .{});
    print("192.168.0.2/32 should contain 192.168.0.3: false (only contains 192.168.0.2)\n", .{});
    print("192.168.0.0/26 should contain 192.168.0.3: true (contains 192.168.0.0-192.168.0.63)\n", .{});
} 