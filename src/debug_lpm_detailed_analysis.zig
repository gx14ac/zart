const std = @import("std");
const print = std.debug.print;
const Table = @import("table.zig").Table;
const Node = @import("direct_node.zig").DirectNode;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;
const base_index = @import("base_index.zig");
const lookup_tbl = @import("lookup_tbl.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 問題のプレフィックスを設定
    var table = Table(i32).init(allocator);
    defer table.deinit();

    // プレフィックスの挿入
    const pfx_26 = Prefix.init(&IPAddr{ .v4 = [4]u8{ 192, 168, 0, 0 } }, 26);
    const pfx_1_32 = Prefix.init(&IPAddr{ .v4 = [4]u8{ 192, 168, 0, 1 } }, 32);
    const pfx_2_32 = Prefix.init(&IPAddr{ .v4 = [4]u8{ 192, 168, 0, 2 } }, 32);
    const pfx_2_31 = Prefix.init(&IPAddr{ .v4 = [4]u8{ 192, 168, 0, 2 } }, 31);
    
    table.insert(&pfx_26, 4);
    table.insert(&pfx_1_32, 1);
    table.insert(&pfx_2_32, 2);
    table.insert(&pfx_2_31, 7);

    print("=== ZART LookupPrefixLPM Debug Analysis ===\n", .{});
    print("Inserted prefixes:\n", .{});
    print("  192.168.0.0/26 → 4\n", .{});
    print("  192.168.0.1/32 → 1\n", .{});
    print("  192.168.0.2/32 → 2\n", .{});
    print("  192.168.0.2/31 → 7\n", .{});
    print("\n", .{});

    // 192.168.0.3の詳細分析
    const test_prefix = Prefix.init(&IPAddr{ .v4 = [4]u8{ 192, 168, 0, 3 } }, 32);
    print("Testing: 192.168.0.3/32\n", .{});
    
    // 包含関係確認
    print("\n=== Containment Check ===\n", .{});
    
    print("192.168.0.0/26 contains 192.168.0.3: {}\n", .{pfx_26.containsAddr(test_prefix.addr)});
    print("192.168.0.2/31 contains 192.168.0.3: {}\n", .{pfx_2_31.containsAddr(test_prefix.addr)});
    print("192.168.0.2/32 contains 192.168.0.3: {}\n", .{pfx_2_32.containsAddr(test_prefix.addr)});
    
    // 実際のLookupPrefixLPM実行
    print("\n=== LookupPrefixLPM Analysis ===\n", .{});
    const result = table.lookupPrefixLPM(&test_prefix);
    print("Result: value={?}, ok={}\n", .{result, result != null});

    // IPv4ルートノードの詳細分析
    print("\n=== IPv4 Root Node Analysis ===\n", .{});
    const root4 = table.root4;
    analyzeNodePrefixes(root4, 0, "root4");
    
    // 手動でbacktrackingを実行
    print("\n=== Manual Backtracking Simulation ===\n", .{});
    manualBacktrackingSimulation(root4, &test_prefix);
}

fn analyzeNodePrefixes(node: *const Node(i32), depth: usize, label: []const u8) void {
    print("Node {s} (depth {}): prefixes_len={}\n", .{ label, depth, node.prefixes_len });
    
    if (node.prefixes_len > 0) {
        print("  Prefixes bitset: (prefixes_len={})\n", .{node.prefixes_len});
        print("  Prefixes items:\n", .{});
        for (node.prefixes_items[0..node.prefixes_len], 0..) |item, i| {
            print("    [{}] value={}\n", .{ i, item });
        }
    }
    
    if (node.children_len > 0) {
        print("  Children bitset: (children_len={})\n", .{node.children_len});
        print("  Children count: {}\n", .{node.children_len});
        
        // 最初の数個の子ノードを分析
        var count: usize = 0;
        for (0..256) |i| {
            if (node.children_bitset.isSet(@intCast(i))) {
                if (count < 3) { // 最初の3個のみ
                    const rank = node.children_bitset.rank(@intCast(i)) - 1;
                    const child = node.children_items[rank];
                    print("  Child[{}] (rank={}):\n", .{ i, rank });
                    analyzeNodePrefixes(child, depth + 1, "child");
                }
                count += 1;
            }
        }
    }
}

fn manualBacktrackingSimulation(root: *const Node(i32), pfx: *const Prefix) void {
    const canonical_pfx = pfx.masked();
    const ip = canonical_pfx.addr;
    const bits = canonical_pfx.bits;
    const octets = ip.asSlice();
    
    print("Input: ip={}, bits={}\n", .{ ip, bits });
    print("Octets: {any}\n", .{octets});
    
    const max_depth_info = base_index.maxDepthAndLastBits(bits);
    const max_depth = max_depth_info.max_depth;
    const last_bits = max_depth_info.last_bits;
    
    print("Max depth: {}, last bits: {}\n", .{ max_depth, last_bits });
    
    // stackを模擬
    var stack: [16]*const Node(i32) = undefined;
    var depth: usize = 0;
    var n = root;
    
    print("\n=== Forward Traversal ===\n", .{});
    for (octets, 0..) |octet, d| {
        depth = d & 0xf;
        
        if (depth > max_depth) {
            depth -= 1;
            break;
        }
        
        stack[depth] = n;
        print("Depth {}: octet={}, pushing node to stack\n", .{ depth, octet });
        
        if (!n.children_bitset.isSet(octet)) {
            print("  No child found for octet {}\n", .{octet});
            break;
        }
        
        const rank_idx = n.children_bitset.rank(octet) - 1;
        n = n.children_items[rank_idx];
        print("  Found child at rank {}\n", .{rank_idx});
    }
    
    print("\n=== Backtracking ===\n", .{});
    var backtrack_depth: i32 = @intCast(depth);
    while (backtrack_depth >= 0) : (backtrack_depth -= 1) {
        const current_depth = @as(usize, @intCast(backtrack_depth)) & 0xf;
        
        n = stack[current_depth];
        print("Backtrack depth {}: prefixes_len={}\n", .{ current_depth, n.prefixes_len });
        
        if (n.prefixes_len == 0) {
            print("  No prefixes at this depth\n", .{});
            continue;
        }
        
        const current_octet: u8 = octets[current_depth];
        var idx: usize = 0;
        if (current_depth == max_depth) {
            idx = base_index.pfxToIdx256(current_octet, last_bits);
            print("  Using pfxToIdx256({}, {}): idx={}\n", .{ current_octet, last_bits, idx });
        } else {
            idx = base_index.hostIdx(current_octet);
            print("  Using hostIdx({}): idx={}\n", .{ current_octet, idx });
        }
        
        const bs = lookup_tbl.backTrackingBitset(idx);
        print("  BackTrackingBitset({}): (bitset)\n", .{idx});
        print("  Node prefixes_bitset: (bitset)\n", .{});
        
        if (n.prefixes_bitset.intersectionTop(&bs)) |top_idx| {
            print("  IntersectionTop found: top_idx={}\n", .{top_idx});
            const rank_idx = n.prefixes_bitset.rank(top_idx) - 1;
            const val = n.prefixes_items[rank_idx];
            print("  Rank: {}, Value: {}\n", .{ rank_idx, val });
            
            // プレフィックス長を計算
            const pfx_len = base_index.pfxLen256(@intCast(current_depth), top_idx) catch {
                print("  ERROR: pfxLen256 failed\n", .{});
                continue;
            };
            
            print("  Prefix length: {}\n", .{pfx_len});
            
            // プレフィックス再構築
            var lmp_addr = ip;
            lmp_addr = lmp_addr.masked(pfx_len);
            const lmp_pfx = Prefix.init(&lmp_addr, pfx_len);
            print("  LMP prefix: {}\n", .{lmp_pfx});
            
            print("  *** RESULT: value={}, prefix={} ***\n", .{ val, lmp_pfx });
            return;
        } else {
            print("  No intersection found\n", .{});
        }
    }
    
    print("  No match found\n", .{});
} 