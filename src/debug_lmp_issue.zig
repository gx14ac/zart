const std = @import("std");
const table_mod = @import("table.zig");
const node_mod = @import("node.zig");
const print = std.debug.print;

const Table = table_mod.Table;
const Prefix = node_mod.Prefix;
const IPAddr = node_mod.IPAddr;

/// Helper function - equivalent to Go BART's netip.MustParseAddr
fn mpa(addr_str: []const u8) IPAddr {
    return parseIPAddress(addr_str) catch {
        std.debug.panic("Invalid IP address: {s}\n", .{addr_str});
    };
}

/// Helper function - equivalent to Go BART's netip.MustParsePrefix
fn mpp(prefix_str: []const u8) Prefix {
    const slash_pos = std.mem.indexOf(u8, prefix_str, "/") orelse {
        std.debug.panic("Invalid prefix (no /): {s}\n", .{prefix_str});
    };
    
    const addr_str = prefix_str[0..slash_pos];
    const len_str = prefix_str[slash_pos + 1..];
    
    const prefix_len = std.fmt.parseInt(u8, len_str, 10) catch {
        std.debug.panic("Invalid prefix length: {s}\n", .{len_str});
    };
    
    const addr = parseIPAddress(addr_str) catch {
        std.debug.panic("Invalid IP address in prefix: {s}\n", .{addr_str});
    };
    
    const is_valid = switch (addr) {
        .v4 => prefix_len <= 32,
        .v6 => prefix_len <= 128,
    };
    if (!is_valid) {
        std.debug.panic("Invalid prefix length for IP version: {s}\n", .{prefix_str});
    }
    
    const prefix = Prefix.init(&addr, prefix_len);
    return prefix.masked();
}

/// Parse IP address from string - supports both IPv4 and IPv6
fn parseIPAddress(addr_str: []const u8) !IPAddr {
    if (std.mem.indexOf(u8, addr_str, ":") == null) {
        // IPv4
        var parts: [4]u8 = undefined;
        var iter = std.mem.splitScalar(u8, addr_str, '.');
        var i: usize = 0;

        while (iter.next()) |part| {
            if (i >= 4) return error.InvalidIPv4;
            parts[i] = std.fmt.parseInt(u8, part, 10) catch return error.InvalidIPv4;
            i += 1;
        }

        if (i != 4) return error.InvalidIPv4;
        return IPAddr{ .v4 = parts };
    } else {
        // IPv6 - simplified parsing for test purposes
        var parts: [16]u8 = std.mem.zeroes([16]u8);
        
        if (std.mem.startsWith(u8, addr_str, "::")) {
            // Handle :: notation
            return IPAddr{ .v6 = parts };
        } else if (std.mem.startsWith(u8, addr_str, "2001:db8")) {
            parts[0] = 0x20; parts[1] = 0x01; parts[2] = 0x0d; parts[3] = 0xb8;
        } else if (std.mem.startsWith(u8, addr_str, "fe80")) {
            parts[0] = 0xfe; parts[1] = 0x80;
        } else if (std.mem.startsWith(u8, addr_str, "ff:aaaa")) {
            parts[0] = 0xff; parts[1] = 0xaa; parts[2] = 0xaa;
        } else if (std.mem.startsWith(u8, addr_str, "ff:cccc")) {
            parts[0] = 0xff; parts[1] = 0xcc; parts[2] = 0xcc;
        } else if (std.mem.startsWith(u8, addr_str, "ffff:bbbb")) {
            parts[0] = 0xff; parts[1] = 0xff; parts[2] = 0xbb; parts[3] = 0xbb;
        }
        
        return IPAddr{ .v6 = parts };
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== 192.168.0.3 LPM Debug Test ===\n", .{});

    var table = Table(i32).init(allocator);
    defer table.deinit();

    // Test 1: 192.168.0.1/32 のみ
    print("\n1. Insert 192.168.0.1/32 -> 1\n", .{});
    table.insert(&mpp("192.168.0.1/32"), 1);
    
    // 192.168.0.3 を検索
    const addr3 = mpa("192.168.0.3");
    const lookup1 = table.lookup(&addr3);
    print("   192.168.0.3 lookup: ok={}, value={}\n", .{lookup1.ok, if (lookup1.ok) lookup1.value else -1});
    
    // Test 2: 192.168.0.2/32 を追加
    print("\n2. Insert 192.168.0.2/32 -> 2\n", .{});
    table.insert(&mpp("192.168.0.2/32"), 2);
    
    // 192.168.0.3 を再検索
    const lookup2 = table.lookup(&addr3);
    print("   192.168.0.3 lookup: ok={}, value={}\n", .{lookup2.ok, if (lookup2.ok) lookup2.value else -1});
    
    // 詳細なデバッグ情報
    print("\n=== Debug Info ===\n", .{});
    print("Table size: {}\n", .{table.size()});
    
    // 各アドレスを確認
    const addr1 = mpa("192.168.0.1");
    const addr2 = mpa("192.168.0.2");
    
    const lookup_addr1 = table.lookup(&addr1);
    const lookup_addr2 = table.lookup(&addr2);
    
    print("192.168.0.1 lookup: ok={}, value={}\n", .{lookup_addr1.ok, if (lookup_addr1.ok) lookup_addr1.value else -1});
    print("192.168.0.2 lookup: ok={}, value={}\n", .{lookup_addr2.ok, if (lookup_addr2.ok) lookup_addr2.value else -1});
    
    // Test 3: 192.168.0.0/26 を追加
    print("\n3. Insert 192.168.0.0/26 -> 7\n", .{});
    table.insert(&mpp("192.168.0.0/26"), 7);
    
    // 192.168.0.3 を再検索
    const lookup3 = table.lookup(&addr3);
    print("   192.168.0.3 lookup: ok={}, value={}\n", .{lookup3.ok, if (lookup3.ok) lookup3.value else -1});
    
    // 理論的に192.168.0.0/26は192.168.0.0-192.168.0.63をカバーする
    print("\n=== 192.168.0.0/26 Coverage Test ===\n", .{});
    const test_addrs = [_][]const u8{
        "192.168.0.0", "192.168.0.1", "192.168.0.2", "192.168.0.3",
        "192.168.0.63", "192.168.0.64", "192.168.0.255"
    };
    
    for (test_addrs) |addr_str| {
        const test_addr = mpa(addr_str);
        const test_lookup = table.lookup(&test_addr);
        print("   {s} lookup: ok={}, value={}\n", .{addr_str, test_lookup.ok, if (test_lookup.ok) test_lookup.value else -1});
    }
} 