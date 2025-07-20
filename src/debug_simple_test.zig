const std = @import("std");
const print = std.debug.print;
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;

fn mpp(prefix_str: []const u8) Prefix {
    const slash_pos = std.mem.indexOf(u8, prefix_str, "/") orelse {
        std.debug.panic("Invalid prefix (no /): {s}\n", .{prefix_str});
    };
    
    const addr_str = prefix_str[0..slash_pos];
    const len_str = prefix_str[slash_pos + 1..];
    
    const prefix_len = std.fmt.parseInt(u8, len_str, 10) catch {
        std.debug.panic("Invalid prefix length: {s}\n", .{len_str});
    };
    
    // 簡単なIPv4パース
    var parts: [4]u8 = undefined;
    var iter = std.mem.splitScalar(u8, addr_str, '.');
    var i: usize = 0;
    while (iter.next()) |part| {
        if (i >= 4) std.debug.panic("Invalid IPv4\n", .{});
        parts[i] = std.fmt.parseInt(u8, part, 10) catch std.debug.panic("Invalid IPv4 part\n", .{});
        i += 1;
    }
    if (i != 4) std.debug.panic("Invalid IPv4\n", .{});
    
    const addr = IPAddr{ .v4 = parts };
    const prefix = Prefix.init(&addr, prefix_len);
    return prefix.masked();
}

fn mpa(addr_str: []const u8) IPAddr {
    // 簡単なIPv4パース
    var parts: [4]u8 = undefined;
    var iter = std.mem.splitScalar(u8, addr_str, '.');
    var i: usize = 0;
    while (iter.next()) |part| {
        if (i >= 4) std.debug.panic("Invalid IPv4\n", .{});
        parts[i] = std.fmt.parseInt(u8, part, 10) catch std.debug.panic("Invalid IPv4 part\n", .{});
        i += 1;
    }
    if (i != 4) std.debug.panic("Invalid IPv4\n", .{});
    
    return IPAddr{ .v4 = parts };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== Simple Insert/Lookup Test ===\n", .{});
    
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    print("Step 1: Insert 192.168.0.1/32 -> 1\n", .{});
    const prefix = mpp("192.168.0.1/32");
    print("Prefix: addr={}, bits={}\n", .{ prefix.addr, prefix.bits });
    
    table.insert(&prefix, 1);
    print("Insert completed\n", .{});
    
    print("Step 2: Lookup 192.168.0.1\n", .{});
    const addr = mpa("192.168.0.1");
    print("Address: {}\n", .{addr});
    
    const result = table.lookup(&addr);
    print("Lookup result: value={}, ok={}\n", .{ result.value, result.ok });
    
    if (result.ok and result.value == 1) {
        print("✅ SUCCESS: Lookup works correctly!\n", .{});
    } else {
        print("❌ FAILED: Lookup failed\n", .{});
        
        // Debug table state
        print("Table size: {}\n", .{table.size()});
        print("Table IPv4 size: {}\n", .{table.getSize4()});
        print("Table IPv6 size: {}\n", .{table.getSize6()});
    }
} 