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

/// 詳細なプレフィックス分析
fn analyzePrefixIndex(prefix_str: []const u8, expected_value: i32) void {
    const pfx = mpp(prefix_str);
    const octets = pfx.addr.asSlice();
    
    // プレフィックス長の計算
    const max_depth_info = base_index.maxDepthAndLastBits(pfx.bits);
    const max_depth = max_depth_info.max_depth;
    const last_bits = max_depth_info.last_bits;
    
    print("=== Prefix Analysis: {s} → {} ===\n", .{prefix_str, expected_value});
    print("  bits: {}, max_depth: {}, last_bits: {}\n", .{pfx.bits, max_depth, last_bits});
    
    // 各深度でのオクテットとインデックス
    for (octets, 0..) |octet, depth| {
        if (depth <= max_depth) {
            if (depth == max_depth) {
                const idx = base_index.pfxToIdx256(octet, last_bits);
                print("  depth {}: octet={}, pfxToIdx256({}, {}) = {}\n", .{depth, octet, octet, last_bits, idx});
            } else {
                const host_idx = base_index.hostIdx(octet);
                print("  depth {}: octet={}, hostIdx({}) = {}\n", .{depth, octet, octet, host_idx});
            }
        }
    }
         print("\n", .{});
 }
 
 /// 詳細なbacktracking分析
 fn analyzeBacktracking(addr_str: []const u8) void {
     const addr = mpa(addr_str);
     const octets = addr.asSlice();
     
     print("=== Backtracking Analysis: {s} ===\n", .{addr_str});
     
     for (octets, 0..) |octet, depth| {
         const host_idx = base_index.hostIdx(octet);
         const bs = lookup_tbl.backTrackingBitset(host_idx);
         
         print("  depth {}: octet={}, hostIdx={}\n", .{depth, octet, host_idx});
         print("    backtrackingBitset bits set: ", .{});
         
         var count: u8 = 0;
         var idx: u8 = 0;
         while (idx < 255 and count < 20) : (idx += 1) {  // idx < 255に変更
             if (bs.isSet(idx)) {
                 print("{} ", .{idx});
                 count += 1;
             }
         }
         // idx=255も確認
         if (count < 20 and bs.isSet(255)) {
             print("255 ", .{});
             count += 1;
         }
         if (count >= 20) {
             print("... (truncated)", .{});
         }
         print("\n", .{});
     }
     print("\n", .{});
}

/// BitSet256の状態を表示
fn printBitSet(name: []const u8, bs: *const BitSet256) void {
    print("  {s} bits set: ", .{name});
    
         var count: u8 = 0;
     var idx: u8 = 0;
     while (idx < 255 and count < 20) : (idx += 1) {
         if (bs.isSet(idx)) {
             print("{} ", .{idx});
             count += 1;
         }
     }
     // idx=255も確認
     if (count < 20 and bs.isSet(255)) {
         print("255 ", .{});
         count += 1;
     }
    if (count >= 20) {
        print("... (truncated)", .{});
    }
    print(" (total: {} bits)\n", .{bs.cardinality()});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== LMP Bug Analysis ===\n\n", .{});

    // 各プレフィックスのインデックス分析
    analyzePrefixIndex("192.168.0.1/32", 1);
    analyzePrefixIndex("192.168.0.2/32", 2);
    analyzePrefixIndex("192.168.0.0/26", 7);
    
    // 192.168.0.3のbacktracking分析
    analyzeBacktracking("192.168.0.3");

         // 実際のテーブル操作を再現
     print("=== Table Operations Reproduction ===\n", .{});
     var table = Table(i32).init(allocator);
     defer table.deinit();
 
     // Step 1: Insert 192.168.0.1/32 → 1
     print("\n1. Insert 192.168.0.1/32 → 1\n", .{});
     table.insert(&mpp("192.168.0.1/32"), 1);
     
     // Test lookup for 192.168.0.3
     const addr3 = mpa("192.168.0.3");
     const lookup1 = table.lookup(&addr3);
     print("   192.168.0.3 lookup: ok={}, value={}\n", .{lookup1.ok, if (lookup1.ok) lookup1.value else -1});
     
     // Step 2: Insert 192.168.0.2/32 → 2
     print("\n2. Insert 192.168.0.2/32 → 2\n", .{});
     table.insert(&mpp("192.168.0.2/32"), 2);
     
     // Test lookup for 192.168.0.3 again
     const lookup2 = table.lookup(&addr3);
     print("   192.168.0.3 lookup: ok={}, value={} ← PROBLEM HERE\n", .{lookup2.ok, if (lookup2.ok) lookup2.value else -1});
     
     // Step 3: Insert 192.168.0.0/26 → 7
     print("\n3. Insert 192.168.0.0/26 → 7\n", .{});
     table.insert(&mpp("192.168.0.0/26"), 7);
     
     // Test lookup for 192.168.0.3 final
     const lookup3 = table.lookup(&addr3);
     print("   192.168.0.3 lookup: ok={}, value={} ← Should be 7, not 2\n", .{lookup3.ok, if (lookup3.ok) lookup3.value else -1});
     
     // 詳細な根本原因分析
     print("\n=== Root Cause Analysis ===\n", .{});
     print("Expected behavior:\n", .{});
     print("  192.168.0.3 ∉ 192.168.0.1/32 (different host)\n", .{});
     print("  192.168.0.3 ∉ 192.168.0.2/32 (different host)\n", .{});
     print("  192.168.0.3 ∈ 192.168.0.0/26  (in subnet range 192.168.0.0-192.168.0.63)\n", .{});
     print("  Therefore: 192.168.0.3 should match 192.168.0.0/26 → value=7\n", .{});
     
     // backtrackingBitset算法の詳細分析
     print("\n=== BacktrackingBitset Algorithm Analysis ===\n", .{});
     const host_idx_3 = base_index.hostIdx(3);  // 192.168.0.3の最後のオクテット
     const bs_3 = lookup_tbl.backTrackingBitset(host_idx_3);
     
     print("192.168.0.3 depth=3, octet=3, hostIdx={}\n", .{host_idx_3});
     
     // 各プレフィックスのインデックスをチェック
     const pfx_idx_1 = base_index.pfxToIdx256(1, 8);  // 192.168.0.1/32の最後のオクテット
     const pfx_idx_2 = base_index.pfxToIdx256(2, 8);  // 192.168.0.2/32の最後のオクテット
     const pfx_idx_26 = base_index.pfxToIdx256(0, 2); // 192.168.0.0/26の最後のオクテット (0, 26%8=2)
     
     print("Prefix indices:\n", .{});
     print("  192.168.0.1/32 → pfxToIdx256(1, 8) = {}\n", .{pfx_idx_1});
     print("  192.168.0.2/32 → pfxToIdx256(2, 8) = {}\n", .{pfx_idx_2});
     print("  192.168.0.0/26 → pfxToIdx256(0, 2) = {}\n", .{pfx_idx_26});
     
     print("Backtracking intersection test:\n", .{});
     print("  bs_3.isSet({}) (pfx_1) = {}\n", .{pfx_idx_1, bs_3.isSet(pfx_idx_1)});
     print("  bs_3.isSet({}) (pfx_2) = {}\n", .{pfx_idx_2, bs_3.isSet(pfx_idx_2)});
     print("  bs_3.isSet({}) (pfx_26) = {}\n", .{pfx_idx_26, bs_3.isSet(pfx_idx_26)});
     
     // Test containsAddr method for each prefix
     print("\nContainsAddr test for 192.168.0.3:\n", .{});
     
     // Test 192.168.0.1/32
     const pfx_1 = mpp("192.168.0.1/32");
     const contains_1 = pfx_1.containsAddr(addr3);
     print("  192.168.0.1/32.containsAddr(192.168.0.3) = {} (should be false)\n", .{contains_1});
     
     // Test 192.168.0.2/32
     const pfx_2 = mpp("192.168.0.2/32");
     const contains_2 = pfx_2.containsAddr(addr3);
     print("  192.168.0.2/32.containsAddr(192.168.0.3) = {} (should be false)\n", .{contains_2});
     
     // Test 192.168.0.0/26
     const pfx_26 = mpp("192.168.0.0/26");
     const contains_26 = pfx_26.containsAddr(addr3);
     print("  192.168.0.0/26.containsAddr(192.168.0.3) = {} (should be true)\n", .{contains_26});
} 