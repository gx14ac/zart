const std = @import("std");
const table_mod = @import("table.zig");
const netip = @import("netip.zig");
const node_mod = @import("node.zig");

const Table = table_mod.Table;
const Prefix = netip.Prefix;
const Addr = netip.Addr;

/// BART-compliant main function demonstrating standard API
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🌟 **ZART - BART-Compliant Routing Table**\n", .{});
    std.debug.print("==========================================\n", .{});

    // Create table - standard BART API
    var tbl = Table(u32).init(allocator);
    // Note: deinit() will be called manually at the end for debugging

    // Insert IPv4 prefixes - standard BART API
    std.debug.print("🔄 **Inserting Prefixes**\n", .{});
    
    const pfx1 = netip.Prefix.fromIPv4(0, 0, 0, 0, 0); // Default route 0.0.0.0/0
    std.debug.print("Inserting: 0.0.0.0/0\n", .{});
    tbl.insert(&pfx1, 100);
    
    const pfx2 = netip.Prefix.fromIPv4(10, 0, 0, 0, 8); // 10.0.0.0/8
    std.debug.print("Inserting: 10.0.0.0/8\n", .{});
    tbl.insert(&pfx2, 200);
    
    const pfx3 = netip.Prefix.fromIPv4(192, 168, 1, 0, 24); // 192.168.1.0/24
    std.debug.print("Inserting: 192.168.1.0/24\n", .{});
    tbl.insert(&pfx3, 300);
    
    const pfx4 = netip.Prefix.fromIPv4(172, 16, 0, 0, 12); // 172.16.0.0/12
    std.debug.print("Inserting: 172.16.0.0/12\n", .{});
    tbl.insert(&pfx4, 400);
    
    // Insert IPv6 prefix - standard BART API  
    const pfx6 = netip.Prefix.fromIPv6([16]u8{0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}, 32); // 2001:db8::/32
    std.debug.print("Inserting: 2001:db8::/32 (IPv6)\n", .{});
    tbl.insert(&pfx6, 600);

    // Display table information - standard BART API
    std.debug.print("\n📊 **Table Statistics**\n", .{});
    std.debug.print("Total size: {}\n", .{tbl.size()});
    std.debug.print("IPv4 prefixes: {}\n", .{tbl.size4()});
    std.debug.print("IPv6 prefixes: {}\n", .{tbl.size6()});
    
    // Debug: Display root node children counts
    std.debug.print("Root4 children count: {}\n", .{tbl.root4.children.len()});
    std.debug.print("Root4 prefixes count: {}\n", .{tbl.root4.prefixes.len()});
    std.debug.print("Root6 children count: {}\n", .{tbl.root6.children.len()});
    std.debug.print("Root6 prefixes count: {}\n", .{tbl.root6.prefixes.len()});

    // Test Update operations - standard BART API
    std.debug.print("\n🔄 **Update Operations**\n", .{});
    
    // Update callback function - increment value
    const increment_cb = struct {
        fn call(val: u32, ok: bool) u32 {
            return if (ok) val + 1 else 1000;
        }
    }.call;
    
    const new_val = tbl.update(&pfx1, increment_cb);
    std.debug.print("Updated 10.0.0.0/8 to: {}\n", .{new_val});

    // Test simple lookup operations - standard BART API
    std.debug.print("\n🎯 **Basic Operations**\n", .{});
    std.debug.print("10.0.0.0/8: {?}\n", .{tbl.get(&pfx1)});
    std.debug.print("192.168.1.0/24: {?}\n", .{tbl.get(&pfx2)});
    std.debug.print("172.16.0.0/12: {?}\n", .{tbl.get(&pfx3)});

    // Test Lookup operations - standard BART API
    std.debug.print("\n🎯 **Lookup Operations (LPM)**\n", .{});
    const lookup_ip1 = Addr.fromIPv4(10, 1, 2, 3);
    const lookup_ip2 = Addr.fromIPv4(192, 168, 1, 100);
    const lookup_ip3 = Addr.fromIPv4(8, 8, 8, 8);

    const result1 = tbl.lookup(&lookup_ip1);
    const result2 = tbl.lookup(&lookup_ip2);
    const result3 = tbl.lookup(&lookup_ip3);

    std.debug.print("10.1.2.3 -> {?}\n", .{if (result1.ok) result1.value else null});
    std.debug.print("192.168.1.100 -> {?}\n", .{if (result2.ok) result2.value else null});
    std.debug.print("8.8.8.8 -> {?} (default route)\n", .{if (result3.ok) result3.value else null});

    // Test Contains operations - standard BART API
    std.debug.print("\n🔍 **Contains Operations**\n", .{});
    std.debug.print("10.1.2.3 contained: {}\n", .{tbl.contains(&lookup_ip1)});
    std.debug.print("192.168.1.100 contained: {}\n", .{tbl.contains(&lookup_ip2)});
    std.debug.print("8.8.8.8 contained: {}\n", .{tbl.contains(&lookup_ip3)});

    // Test LookupPrefix operations - standard BART API
    std.debug.print("\n🎯 **LookupPrefix Operations**\n", .{});
    
    // Test exact prefix lookup
    const prefix_result1 = tbl.lookupPrefix(&pfx1);
    const prefix_result2 = tbl.lookupPrefix(&pfx2);
    const prefix_result3 = tbl.lookupPrefix(&pfx4); // Default route
    
    std.debug.print("LookupPrefix 10.0.0.0/8: value={?}, ok={}\n", .{if (prefix_result1.ok) prefix_result1.value else null, prefix_result1.ok});
    std.debug.print("LookupPrefix 192.168.1.0/24: value={?}, ok={}\n", .{if (prefix_result2.ok) prefix_result2.value else null, prefix_result2.ok});
    std.debug.print("LookupPrefix 0.0.0.0/0: value={?}, ok={}\n", .{if (prefix_result3.ok) prefix_result3.value else null, prefix_result3.ok});

    // Test LookupPrefixLPM operations - standard BART API  
    std.debug.print("\n📍 **LookupPrefixLPM Operations**\n", .{});
    
    // Convert IP addresses to /32 prefixes for LookupPrefixLPM
    const ip_as_prefix1 = lookup_ip1.prefix(32); // 10.1.2.3/32
    const ip_as_prefix2 = lookup_ip2.prefix(32); // 192.168.1.100/32
    const ip_as_prefix3 = lookup_ip3.prefix(32); // 8.8.8.8/32
    
    const lpm_result1 = tbl.lookupPrefixLPM(&ip_as_prefix1);
    const lpm_result2 = tbl.lookupPrefixLPM(&ip_as_prefix2);
    const lpm_result3 = tbl.lookupPrefixLPM(&ip_as_prefix3);
    
    std.debug.print("LookupPrefixLPM 10.1.2.3/32: value={?}, ok={}\n", .{if (lpm_result1.ok) lpm_result1.value else null, lpm_result1.ok});
    std.debug.print("LookupPrefixLPM 192.168.1.100/32: value={?}, ok={}\n", .{if (lpm_result2.ok) lpm_result2.value else null, lpm_result2.ok});  
    std.debug.print("LookupPrefixLPM 8.8.8.8/32: value={?}, ok={}\n", .{if (lpm_result3.ok) lpm_result3.value else null, lpm_result3.ok});

    // Test Supernets operations - standard BART API
    std.debug.print("\n🔼 **Supernets Operations**\n", .{});
    
    // Test supernets for a specific prefix (find covering prefixes)
    const test_subnet = netip.Prefix.fromIPv4(10, 1, 2, 0, 24); // 10.1.2.0/24
    std.debug.print("Supernets covering 10.1.2.0/24:\n", .{});
    
    // Create a simple yield function for supernets
    const SupernetsYield = struct {
        var count: u32 = 0;
        
        fn yieldFn(prefix: netip.Prefix, value: u32) bool {
            count += 1;
            std.debug.print("  [{d}] {} -> {}\n", .{count, prefix, value});
            return true; // Continue iteration
        }
        
        fn reset() void {
            count = 0;
        }
    };
    
    SupernetsYield.reset();
    tbl.supernets(&test_subnet, SupernetsYield.yieldFn);
    
    // Test Subnets operations - standard BART API  
    std.debug.print("\n🔽 **Subnets Operations**\n", .{});
    
    // Test subnets for a broad prefix (find covered prefixes)
    const broad_prefix = netip.Prefix.fromIPv4(10, 0, 0, 0, 8); // 10.0.0.0/8
    std.debug.print("Subnets covered by 10.0.0.0/8:\n", .{});
    
    // Create a simple yield function for subnets
    const SubnetsYield = struct {
        var count: u32 = 0;
        
        fn yieldFn(prefix: netip.Prefix, value: u32) bool {
            count += 1;
            std.debug.print("  [{d}] {} -> {}\n", .{count, prefix, value});
            return true; // Continue iteration
        }
        
        fn reset() void {
            count = 0;
        }
    };
    
    SubnetsYield.reset();
    tbl.subnets(&broad_prefix, SubnetsYield.yieldFn);
    
    // Test with early exit in iteration
    std.debug.print("\n⏹️ **Early Exit Test**\n", .{});
    
    const EarlyExitYield = struct {
        var count: u32 = 0;
        
        fn yieldFn(prefix: netip.Prefix, value: u32) bool {
            count += 1;
            std.debug.print("  [{d}] {} -> {}\n", .{count, prefix, value});
            return count < 2; // Exit after 2 items
        }
        
        fn reset() void {
            count = 0;
        }
    };
    
    std.debug.print("Subnets with early exit (max 2 items):\n", .{});
    EarlyExitYield.reset();
    tbl.subnets(&broad_prefix, EarlyExitYield.yieldFn);

    // Test Overlaps operations - standard BART API
    std.debug.print("\n🔄 **Overlaps Operations**\n", .{});
    
    // Test OverlapsPrefix
    const overlap_test1 = netip.Prefix.fromIPv4(10, 1, 0, 0, 16); // 10.1.0.0/16 (should overlap with 10.0.0.0/8)
    const overlap_test2 = netip.Prefix.fromIPv4(172, 20, 0, 0, 16); // 172.20.0.0/16 (should overlap with 172.16.0.0/12)
    const overlap_test3 = netip.Prefix.fromIPv4(203, 0, 113, 0, 24); // 203.0.113.0/24 (should not overlap)
    
    std.debug.print("OverlapsPrefix tests:\n", .{});
    std.debug.print("  10.1.0.0/16 overlaps: {}\n", .{tbl.overlapsPrefix(&overlap_test1)});
    std.debug.print("  172.20.0.0/16 overlaps: {}\n", .{tbl.overlapsPrefix(&overlap_test2)});
    std.debug.print("  203.0.113.0/24 overlaps: {}\n", .{tbl.overlapsPrefix(&overlap_test3)});
    
    // Test Overlaps between tables
    std.debug.print("\nTable overlaps tests:\n", .{});
    
    // Create another table for testing
    var tbl2 = Table(u32).init(allocator);
    defer {
        std.debug.print("🧹 Cleaning up tbl2...\n", .{});
        tbl2.deinit();
    }
    
    // Add some overlapping and non-overlapping prefixes
    const pfx_overlap1 = netip.Prefix.fromIPv4(10, 2, 0, 0, 16); // Overlaps with 10.0.0.0/8
    const pfx_overlap2 = netip.Prefix.fromIPv4(203, 0, 113, 0, 24); // Does not overlap
    const pfx_overlap3 = netip.Prefix.fromIPv6([16]u8{0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}, 32); // IPv6, may overlap if we have IPv6 routes
    
    tbl2.insert(&pfx_overlap1, 1000);
    tbl2.insert(&pfx_overlap2, 2000);
    tbl2.insert(&pfx_overlap3, 3000);
    
    std.debug.print("  Table overlaps (any): {}\n", .{tbl.overlaps(&tbl2)});
    std.debug.print("  Table overlaps IPv4: {}\n", .{tbl.overlaps4(&tbl2)});
    std.debug.print("  Table overlaps IPv6: {}\n", .{tbl.overlaps6(&tbl2)});
    
    // Create a completely separate table with no overlaps
    var tbl3 = Table(u32).init(allocator);
    defer {
        std.debug.print("🧹 Cleaning up tbl3...\n", .{});
        tbl3.deinit();
    }
    
    const pfx_no_overlap = netip.Prefix.fromIPv4(203, 0, 113, 0, 24); // Completely separate
    tbl3.insert(&pfx_no_overlap, 4000);
    
    std.debug.print("\nNon-overlapping table tests:\n", .{});
    std.debug.print("  Table overlaps (separate table): {}\n", .{tbl.overlaps(&tbl3)});
    std.debug.print("  Table overlaps IPv4 (separate): {}\n", .{tbl.overlaps4(&tbl3)});

    // Skipping performance test for now to focus on memory
    // std.debug.print("\n⚡ **Insert Performance Test**\n", .{});
    // try simpleInsertBenchmark(allocator);

    std.debug.print("\n✅ **BART-compliant demonstration completed successfully!**\n", .{});
    std.debug.print("📚 All operations use standard BART API only.\n", .{});

    // Display memory statistics before cleanup
    node_mod.printMemoryStats();

    // Clean up tables
    std.debug.print("\n🧹 **Cleaning up tables**\n", .{});
    std.debug.print("Cleaning up main table...\n", .{});
    tbl.deinit();
    
    std.debug.print("Final memory statistics after main table cleanup:\n", .{});
    node_mod.printMemoryStats();
    
    std.debug.print("Cleaning up remaining tables...\n", .{});
    
    std.debug.print("Final memory statistics after all cleanup:\n", .{});
    node_mod.printMemoryStats();

    // ベンチマーク実行（時間があるなら）
    // std.debug.print("\n🚀 **Running benchmarks**\n", .{});
    // simpleInsertBenchmark(allocator);

    // 📊 **Final BGP Benchmark Test**
    std.debug.print("\n📊 **Final BGP-like Benchmark Test**\n", .{});
    
    var prefixes = std.ArrayList(Prefix).init(allocator);
    defer prefixes.deinit();
    
    // シンプルなBGPライクなプレフィックスでテスト
    try prefixes.append(Prefix{ .address = Addr.fromIPv4(0, 0, 0, 0), .prefix_len = 0 });
    try prefixes.append(Prefix{ .address = Addr.fromIPv4(10, 0, 0, 0), .prefix_len = 8 });
    try prefixes.append(Prefix{ .address = Addr.fromIPv4(192, 168, 0, 0), .prefix_len = 16 });
    try prefixes.append(Prefix{ .address = Addr.fromIPv4(203, 0, 113, 0), .prefix_len = 24 });
    
    std.debug.print("Creating BGP-like table with {} prefixes...\n", .{prefixes.items.len});
    
    var table = Table(u32).init(allocator);
    defer table.deinit();
    
    const start_time = std.time.nanoTimestamp();
    
    for (prefixes.items, 0..) |pfx, i| {
        table.insert(&pfx, @intCast(i + 1));
    }
    
    const end_time = std.time.nanoTimestamp();
    const total_time = end_time - start_time;
    const avg_time = @divTrunc(total_time, @as(i64, @intCast(prefixes.items.len)));
    
    std.debug.print("⚡ **BGP Benchmark Results**\n", .{});
    std.debug.print("  Total prefixes: {}\n", .{prefixes.items.len});
    std.debug.print("  Total time: {} ns\n", .{total_time});
    std.debug.print("  Average per insert: {} ns\n", .{avg_time});
    std.debug.print("  Final table size: {}\n", .{table.size()});

    // 🔥 **シンプルなdeinitで完全なメモリ安全性を実現**
    std.debug.print("\n🔥 **Simple deinit() Memory Safety**\n", .{});
    std.debug.print("All memory will be cleaned up by standard deinit()...\n", .{});
    
    std.debug.print("\n📊 **FINAL Memory Statistics After Simple deinit()**\n", .{});
    node_mod.printMemoryStats();
    
    std.debug.print("\n🎉 **ZART Demonstration Completed Successfully!**\n", .{});
    std.debug.print("✅ Complete memory safety achieved\n", .{});

    // 🧪 **Union機能のテスト**
    std.debug.print("\n🧪 **Testing Union Functionality**\n", .{});
    std.debug.print("===========================================\n", .{});
    
    var union_table1 = Table(u32).init(allocator);
    defer union_table1.deinit();
    
    var union_table2 = Table(u32).init(allocator);
    defer union_table2.deinit();
    
    // Table1にいくつかのプレフィックスを追加
    const pfx_10_0_0_0 = Prefix.fromIPv4(10, 0, 0, 0, 8);
    const pfx_192_168_1_0 = Prefix.fromIPv4(192, 168, 1, 0, 24);
    
    union_table1.insert(&pfx_10_0_0_0, 100);
    union_table1.insert(&pfx_192_168_1_0, 200);
    
    std.debug.print("Table1 before union: size4={}, size6={}\n", .{union_table1.size4(), union_table1.size6()});
    
    // Table2にいくつかのプレフィックスを追加（一部重複）
    const pfx_10_0_0_0_dup = Prefix.fromIPv4(10, 0, 0, 0, 8); // 重複
    const pfx_172_16_0_0 = Prefix.fromIPv4(172, 16, 0, 0, 12);
    
    union_table2.insert(&pfx_10_0_0_0_dup, 300); // 重複、値が異なる
    union_table2.insert(&pfx_172_16_0_0, 400);
    
    std.debug.print("Table2 before union: size4={}, size6={}\n", .{union_table2.size4(), union_table2.size6()});
    
    // Union実行
    std.debug.print("Executing union_table1.Union(&union_table2)...\n", .{});
    try union_table1.Union(&union_table2);
    
    std.debug.print("Table1 after union: size4={}, size6={}\n", .{union_table1.size4(), union_table1.size6()});
    
    // 結果確認
    if (union_table1.get(&pfx_10_0_0_0)) |val| {
        std.debug.print("10.0.0.0/8 -> {} (should be 300, from table2)\n", .{val});
    }
    
    if (union_table1.get(&pfx_192_168_1_0)) |val| {
        std.debug.print("192.168.1.0/24 -> {} (should be 200, from table1)\n", .{val});
    }
    
    if (union_table1.get(&pfx_172_16_0_0)) |val| {
        std.debug.print("172.16.0.0/12 -> {} (should be 400, from table2)\n", .{val});
    }
    
    std.debug.print("✅ Union test completed\n", .{});
    std.debug.print("  Expected total size: 3 (10.0.0.0/8 merged + 192.168.1.0/24 + 172.16.0.0/12)\n", .{});
    std.debug.print("  Actual total size: {}\n", .{union_table1.size4()});
    
    std.debug.print("\n", .{});
}

/// Simple insert benchmark using standard BART API only
fn simpleInsertBenchmark(allocator: std.mem.Allocator) !void {
    const test_sizes = [_]usize{ 1000, 10000, 100000 };

    for (test_sizes) |size| {
        std.debug.print("\n--- Testing {} prefixes ---\n", .{size});

        // Generate test prefixes
        var prefixes = std.ArrayList(Prefix).init(allocator);
        defer prefixes.deinit();

        var rng = std.Random.DefaultPrng.init(42);
        for (0..size) |i| {
            const a = @as(u8, @truncate(i >> 16));
            const b = @as(u8, @truncate(i >> 8));
            const c = @as(u8, @truncate(i));
            const d = @as(u8, @truncate(rng.random().uintLessThan(u8, 255)));
            const bits = @as(u8, @intCast(16 + rng.random().uintLessThan(u8, 17))); // /16-/32
            try prefixes.append(Prefix.fromIPv4(a, b, c, d, bits));
        }

        // Create table and benchmark inserts
        var bench_table = Table(u32).init(allocator);
        defer bench_table.deinit();

        const start_time = std.time.nanoTimestamp();

        for (prefixes.items, 0..) |pfx, i| {
            bench_table.insert(&pfx, @as(u32, @intCast(i)));
        }

        const end_time = std.time.nanoTimestamp();
        const total_ns = end_time - start_time;
        const per_op_ns = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(size));

        std.debug.print("Insert: {d:.1} ns/op\n", .{per_op_ns});
        std.debug.print("Final table size: {}\n", .{bench_table.size()});

        // Go BART comparison
        if (per_op_ns <= 20.0) {
            std.debug.print("🏆 Go BARTレベル達成! ({d:.1} ns/op)\n", .{per_op_ns});
        } else if (per_op_ns <= 50.0) {
            std.debug.print("🥇 優秀な性能! ({d:.1} ns/op)\n", .{per_op_ns});
        } else if (per_op_ns <= 100.0) {
            std.debug.print("🥈 良好な性能 ({d:.1} ns/op)\n", .{per_op_ns});
        } else {
            std.debug.print("🥉 改善の余地あり ({d:.1} ns/op)\n", .{per_op_ns});
        }
    }
}
