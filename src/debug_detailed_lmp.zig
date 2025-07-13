const std = @import("std");
const table_mod = @import("table.zig");
const node_mod = @import("node.zig");
const base_index = @import("base_index.zig");
const lookup_tbl = @import("lookup_tbl.zig");
const BitSet256 = @import("bitset256.zig").BitSet256;
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

/// 詳細なbacktrackingの分析
fn analyzeBacktracking(octet: u8, prefix: []const u8) void {
    const host_idx = base_index.hostIdx(octet);
    const bs = lookup_tbl.backTrackingBitset(host_idx);
    
    print("=== Backtracking Analysis for {s} (octet: {}) ===\n", .{prefix, octet});
    print("  hostIdx = {}\n", .{host_idx});
    print("  backtrackingBitset bits set: ", .{});
    
    var count: u8 = 0;
    var idx: u8 = 0;
    while (idx < 256 and count < 10) : (idx += 1) {  // 最大10個まで表示
        if (bs.isSet(idx)) {
            print("{} ", .{idx});
            count += 1;
        }
    }
    if (count >= 10) {
        print("... (truncated)", .{});
    }
    print("\n\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== Detailed LMP Analysis ===\n", .{});

    var table = Table(i32).init(allocator);
    defer table.deinit();

    // Insert 192.168.0.1/32 -> 1
    print("\n1. Insert 192.168.0.1/32 -> 1\n", .{});
    table.insert(&mpp("192.168.0.1/32"), 1);
    
    // Insert 192.168.0.2/32 -> 2
    print("\n2. Insert 192.168.0.2/32 -> 2\n", .{});
    table.insert(&mpp("192.168.0.2/32"), 2);
    
    // Analyze backtracking for 192.168.0.2 and 192.168.0.3
    analyzeBacktracking(2, "192.168.0.2");
    analyzeBacktracking(3, "192.168.0.3");
    
    // Test lookup for 192.168.0.3
    print("=== Lookup Test for 192.168.0.3 ===\n", .{});
    const addr3 = mpa("192.168.0.3");
    const lookup_result = table.lookup(&addr3);
    print("  192.168.0.3 lookup: ok={}, value={}\n", .{lookup_result.ok, if (lookup_result.ok) lookup_result.value else -1});
    
    // Manual bit pattern analysis
    const pfx_idx_2 = base_index.pfxToIdx256(2, 32);
    const pfx_idx_3 = base_index.pfxToIdx256(3, 32);
    
    print("\n=== Prefix Index Analysis ===\n", .{});
    print("  192.168.0.2/32 prefix index: {}\n", .{pfx_idx_2});
    print("  192.168.0.3/32 prefix index: {}\n", .{pfx_idx_3});
    
    // Check if backtracking from 192.168.0.3 would intersect with 192.168.0.2's prefix
    const host_idx_3 = base_index.hostIdx(3);
    const bs_3 = lookup_tbl.backTrackingBitset(host_idx_3);
    
    print("  Does 192.168.0.3 backtracking intersect with 192.168.0.2 prefix index? {}\n", .{bs_3.isSet(pfx_idx_2)});
    print("  Does 192.168.0.3 backtracking intersect with 192.168.0.3 prefix index? {}\n", .{bs_3.isSet(pfx_idx_3)});
} 