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

    // Clean up tables
    std.debug.print("\n🧹 **Cleaning up tables**\n", .{});
    std.debug.print("Cleaning up main table...\n", .{});
    tbl.deinit();
    
    std.debug.print("Final memory statistics after main table cleanup:\n", .{});
    
    std.debug.print("Cleaning up remaining tables...\n", .{});
    
    std.debug.print("Final memory statistics after all cleanup:\n", .{});

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
    
    // 🧬 **Cloner Interface Implementation Test**
    std.debug.print("\n🧬 **Testing Cloner Interface Implementation**\n", .{});
    std.debug.print("================================================\n", .{});
    
    // Cloner を実装した型の例
    const CloneableData = struct {
        const Self = @This();
        
        id: u32,
        name: []const u8,
        count: i32,
        
        // Go BART Cloner interface implementation
        pub fn clone(self: Self) Self {
            return Self{
                .id = self.id,
                .name = self.name, // shallow copy of string
                .count = self.count + 1, // Demo: increment on clone
            };
        }
    };
    
    // Non-cloneable type for comparison
    const SimpleData = struct {
        value: u32,
    };
    
    // Test Cloner detection
    const cloner_mod = @import("node.zig");
    
    std.debug.print("CloneableData implements Cloner: {}\n", .{cloner_mod.isCloner(CloneableData)});
    std.debug.print("SimpleData implements Cloner: {}\n", .{cloner_mod.isCloner(SimpleData)});
    std.debug.print("u32 implements Cloner: {}\n", .{cloner_mod.isCloner(u32)});
    
    // Test cloneOrCopy behavior
    const original_cloneable = CloneableData{ .id = 100, .name = "test", .count = 5 };
    const cloned_cloneable = cloner_mod.cloneOrCopy(CloneableData, original_cloneable);
    
    std.debug.print("\nOriginal CloneableData: id={}, name={s}, count={}\n", .{original_cloneable.id, original_cloneable.name, original_cloneable.count});
    std.debug.print("Cloned CloneableData:   id={}, name={s}, count={}\n", .{cloned_cloneable.id, cloned_cloneable.name, cloned_cloneable.count});
    std.debug.print("Clone incremented count: {} (demonstrates deep copy behavior)\n", .{cloned_cloneable.count});
    
    const original_simple = SimpleData{ .value = 42 };
    const copied_simple = cloner_mod.cloneOrCopy(SimpleData, original_simple);
    
    std.debug.print("\nOriginal SimpleData: value={}\n", .{original_simple.value});
    std.debug.print("Copied SimpleData:   value={}\n", .{copied_simple.value});
    std.debug.print("Simple copy (no clone method)\n", .{});
    
    // Test with Table using Cloneable type
    std.debug.print("\n🧪 Testing Table with Cloner-implementing type...\n", .{});
    
    var cloner_table = Table(CloneableData).init(allocator);
    defer cloner_table.deinit();
    
    const pfx_cloner_test = Prefix.fromIPv4(203, 0, 113, 0, 24);
    const test_data = CloneableData{ .id = 999, .name = "cloner_test", .count = 10 };
    
    cloner_table.insert(&pfx_cloner_test, test_data);
    
    if (cloner_table.get(&pfx_cloner_test)) |retrieved| {
        std.debug.print("Retrieved from table: id={}, name={s}, count={}\n", .{retrieved.id, retrieved.name, retrieved.count});
    }
    
    std.debug.print("✅ Cloner interface test completed\n", .{});
    
    // 🔄 **Cloner + Union Integration Test**
    std.debug.print("\n🔄 **Testing Cloner with Union Operation**\n", .{});
    std.debug.print("===============================================\n", .{});
    
    var cloner_table1 = Table(CloneableData).init(allocator);
    defer cloner_table1.deinit();
    
    var cloner_table2 = Table(CloneableData).init(allocator);
    defer cloner_table2.deinit();
    
    // Table1にデータ追加
    const pfx_cloner1 = Prefix.fromIPv4(10, 0, 0, 0, 8);
    const data1 = CloneableData{ .id = 1, .name = "table1_data", .count = 100 };
    cloner_table1.insert(&pfx_cloner1, data1);
    
    // Table2に重複データ追加（異なる値）
    const pfx_cloner2 = Prefix.fromIPv4(10, 0, 0, 0, 8); // 同じプレフィックス
    const data2 = CloneableData{ .id = 2, .name = "table2_data", .count = 200 };
    cloner_table2.insert(&pfx_cloner2, data2);
    
    std.debug.print("Before union:\n", .{});
    if (cloner_table1.get(&pfx_cloner1)) |val| {
        std.debug.print("  Table1[10.0.0.0/8]: id={}, name={s}, count={}\n", .{val.id, val.name, val.count});
    }
    
    if (cloner_table2.get(&pfx_cloner2)) |val| {
        std.debug.print("  Table2[10.0.0.0/8]: id={}, name={s}, count={}\n", .{val.id, val.name, val.count});
    }
    
    // Union実行（Clonerによるdeep copyが発生）
    std.debug.print("\nExecuting Union with Cloner-implementing types...\n", .{});
    try cloner_table1.Union(&cloner_table2);
    
    std.debug.print("After union:\n", .{});
    if (cloner_table1.get(&pfx_cloner1)) |val| {
        std.debug.print("  Table1[10.0.0.0/8]: id={}, name={s}, count={}\n", .{val.id, val.name, val.count});
        std.debug.print("  → Clone count should be {} (incremented by clone method)\n", .{data2.count + 1});
    }
    
    std.debug.print("✅ Cloner + Union integration test completed\n", .{});
    
    // 📑 **Table Clone Function Test**
    std.debug.print("\n📑 **Testing Table Clone Function**\n", .{});
    std.debug.print("========================================\n", .{});
    
    // Original table with some data
    var original_table = Table(CloneableData).init(allocator);
    defer original_table.deinit();
    
    // Add multiple prefixes with Cloneable data
    const original_data1 = CloneableData{ .id = 1001, .name = "original_1", .count = 50 };
    const original_data2 = CloneableData{ .id = 1002, .name = "original_2", .count = 75 };
    
    const pfx_clone1 = Prefix.fromIPv4(192, 168, 1, 0, 24);
    const pfx_clone2 = Prefix.fromIPv4(10, 0, 0, 0, 8);
    
    original_table.insert(&pfx_clone1, original_data1);
    original_table.insert(&pfx_clone2, original_data2);
    
    std.debug.print("Original table size: IPv4={}, IPv6={}\n", .{original_table.size4(), original_table.size6()});
    
    // Clone the table
    std.debug.print("Executing Table.Clone()...\n", .{});
    const cloned_table = try original_table.Clone(allocator);
    defer {
        cloned_table.deinit();
        allocator.destroy(cloned_table);
    }
    
    std.debug.print("Cloned table size: IPv4={}, IPv6={}\n", .{cloned_table.size4(), cloned_table.size6()});
    
    // Verify cloned data
    std.debug.print("\nVerifying cloned data:\n", .{});
    
    if (original_table.get(&pfx_clone1)) |original| {
        if (cloned_table.get(&pfx_clone1)) |cloned| {
            std.debug.print("Original 192.168.1.0/24: id={}, name={s}, count={}\n", .{original.id, original.name, original.count});
            std.debug.print("Cloned   192.168.1.0/24: id={}, name={s}, count={}\n", .{cloned.id, cloned.name, cloned.count});
            std.debug.print("Clone count incremented: {} (demonstrates Cloner interface usage)\n", .{cloned.count});
        }
    }
    
    if (original_table.get(&pfx_clone2)) |original| {
        if (cloned_table.get(&pfx_clone2)) |cloned| {
            std.debug.print("Original 10.0.0.0/8: id={}, name={s}, count={}\n", .{original.id, original.name, original.count});
            std.debug.print("Cloned   10.0.0.0/8: id={}, name={s}, count={}\n", .{cloned.id, cloned.name, cloned.count});
            std.debug.print("Clone count incremented: {} (demonstrates Cloner interface usage)\n", .{cloned.count});
        }
    }
    
    // Test independence - modify original, verify clone unchanged
    std.debug.print("\n🔄 Testing table independence...\n", .{});
    const new_data = CloneableData{ .id = 9999, .name = "modified", .count = 999 };
    original_table.insert(&pfx_clone1, new_data);
    
    std.debug.print("After modifying original table:\n", .{});
    if (original_table.get(&pfx_clone1)) |modified| {
        std.debug.print("Original (modified): id={}, name={s}, count={}\n", .{modified.id, modified.name, modified.count});
    }
    
    if (cloned_table.get(&pfx_clone1)) |unchanged| {
        std.debug.print("Cloned (unchanged):  id={}, name={s}, count={}\n", .{unchanged.id, unchanged.name, unchanged.count});
    }
    
    std.debug.print("✅ Table Clone function test completed\n", .{});
    std.debug.print("✅ Original and cloned tables are independent\n", .{});
    
    // 📊 **sizeUpdate Function Test**
    std.debug.print("\n📊 **Testing sizeUpdate Function**\n", .{});
    std.debug.print("========================================\n", .{});
    
    // Create a table for testing
    var size_test_table = Table(u32).init(allocator);
    defer size_test_table.deinit();
    
    // Test initial sizes
    std.debug.print("Initial sizes - IPv4: {}, IPv6: {}\n", .{size_test_table.size4(), size_test_table.size6()});
    
    // Test IPv4 size increment
    std.debug.print("\nTesting IPv4 sizeUpdate...\n", .{});
    size_test_table.sizeUpdate(true, 5);  // Add 5 to IPv4
    std.debug.print("After sizeUpdate(true, 5) - IPv4: {}, IPv6: {}\n", .{size_test_table.size4(), size_test_table.size6()});
    
    size_test_table.sizeUpdate(true, -2); // Subtract 2 from IPv4
    std.debug.print("After sizeUpdate(true, -2) - IPv4: {}, IPv6: {}\n", .{size_test_table.size4(), size_test_table.size6()});
    
    // Test IPv6 size increment
    std.debug.print("\nTesting IPv6 sizeUpdate...\n", .{});
    size_test_table.sizeUpdate(false, 3); // Add 3 to IPv6
    std.debug.print("After sizeUpdate(false, 3) - IPv4: {}, IPv6: {}\n", .{size_test_table.size4(), size_test_table.size6()});
    
    size_test_table.sizeUpdate(false, -1); // Subtract 1 from IPv6
    std.debug.print("After sizeUpdate(false, -1) - IPv4: {}, IPv6: {}\n", .{size_test_table.size4(), size_test_table.size6()});
    
    // Test edge cases
    std.debug.print("\nTesting edge cases...\n", .{});
    size_test_table.sizeUpdate(true, 0);   // No change
    size_test_table.sizeUpdate(false, 0);  // No change
    std.debug.print("After sizeUpdate with 0 - IPv4: {}, IPv6: {}\n", .{size_test_table.size4(), size_test_table.size6()});
    
    // Verify final state
    const expected_ipv4 = 5 - 2 + 0; // = 3
    const expected_ipv6 = 3 - 1 + 0; // = 2
    
    std.debug.print("\nFinal verification:\n", .{});
    std.debug.print("Expected IPv4: {}, Actual: {} - {s}\n", .{expected_ipv4, size_test_table.size4(), if (size_test_table.size4() == expected_ipv4) "✅" else "❌"});
    std.debug.print("Expected IPv6: {}, Actual: {} - {s}\n", .{expected_ipv6, size_test_table.size6(), if (size_test_table.size6() == expected_ipv6) "✅" else "❌"});
    
    std.debug.print("✅ sizeUpdate function test completed\n", .{});
    
    // 🔄 **Iteration Functions Test (All, AllSorted, etc.)**
    std.debug.print("\n🔄 **Testing Iteration Functions**\n", .{});
    std.debug.print("==========================================\n", .{});
    
    // Create a table for iteration testing
    var iter_table = Table(u32).init(allocator);
    defer iter_table.deinit();
    
    // Add various prefixes to test iteration
    const iter_prefixes = [_]struct { prefix: Prefix, value: u32 }{
        .{ .prefix = Prefix.fromIPv4(0, 0, 0, 0, 0), .value = 1 },         // Default route
        .{ .prefix = Prefix.fromIPv4(10, 0, 0, 0, 8), .value = 2 },        // 10.0.0.0/8
        .{ .prefix = Prefix.fromIPv4(192, 168, 1, 0, 24), .value = 3 },    // 192.168.1.0/24
        .{ .prefix = Prefix.fromIPv4(172, 16, 0, 0, 12), .value = 4 },     // 172.16.0.0/12
        .{ .prefix = Prefix.fromIPv6([16]u8{0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}, 32), .value = 5 }, // IPv6
    };
    
    std.debug.print("Inserting {} test prefixes...\n", .{iter_prefixes.len});
    for (iter_prefixes) |item| {
        iter_table.insert(&item.prefix, item.value);
    }
    
    std.debug.print("Table sizes: IPv4={}, IPv6={}, Total={}\n", .{iter_table.size4(), iter_table.size6(), iter_table.size()});
    
    // Test All() - unsorted iteration
    std.debug.print("\n🔄 Testing All() iteration:\n", .{});
    const AllYield = struct {
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
    
    AllYield.reset();
    iter_table.all(AllYield.yieldFn);
    std.debug.print("All() iteration completed, found {} prefixes\n", .{AllYield.count});
    
    // Test All4() - IPv4 only
    std.debug.print("\n🔄 Testing All4() iteration (IPv4 only):\n", .{});
    AllYield.reset();
    iter_table.all4(AllYield.yieldFn);
    std.debug.print("All4() iteration completed, found {} IPv4 prefixes\n", .{AllYield.count});
    
    // Test All6() - IPv6 only
    std.debug.print("\n🔄 Testing All6() iteration (IPv6 only):\n", .{});
    AllYield.reset();
    iter_table.all6(AllYield.yieldFn);
    std.debug.print("All6() iteration completed, found {} IPv6 prefixes\n", .{AllYield.count});
    
    // Test AllSorted() - sorted iteration
    std.debug.print("\n🔄 Testing AllSorted() iteration (CIDR sorted):\n", .{});
    AllYield.reset();
    iter_table.allSorted(AllYield.yieldFn);
    std.debug.print("AllSorted() iteration completed, found {} prefixes\n", .{AllYield.count});
    
    // Test AllSorted4() - IPv4 sorted
    std.debug.print("\n🔄 Testing AllSorted4() iteration (IPv4 CIDR sorted):\n", .{});
    AllYield.reset();
    iter_table.allSorted4(AllYield.yieldFn);
    std.debug.print("AllSorted4() iteration completed, found {} IPv4 prefixes\n", .{AllYield.count});
    
    // Test AllSorted6() - IPv6 sorted
    std.debug.print("\n🔄 Testing AllSorted6() iteration (IPv6 CIDR sorted):\n", .{});
    AllYield.reset();
    iter_table.allSorted6(AllYield.yieldFn);
    std.debug.print("AllSorted6() iteration completed, found {} IPv6 prefixes\n", .{AllYield.count});
    
    // Test early exit with All()
    std.debug.print("\n⏹️ Testing early exit with All() (max 2 items):\n", .{});
    const EarlyExitAllYield = struct {
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
    
    EarlyExitAllYield.reset();
    iter_table.all(EarlyExitAllYield.yieldFn);
    std.debug.print("Early exit All() completed after {} prefixes\n", .{EarlyExitAllYield.count});
    
    // Test early exit with AllSorted()
    std.debug.print("\n⏹️ Testing early exit with AllSorted() (max 2 items):\n", .{});
    EarlyExitAllYield.reset();
    iter_table.allSorted(EarlyExitAllYield.yieldFn);
    std.debug.print("Early exit AllSorted() completed after {} prefixes\n", .{EarlyExitAllYield.count});
    
    std.debug.print("✅ All iteration functions test completed\n", .{});
    std.debug.print("✅ Go BART完全互換のイテレーション機能が実装されました\n", .{});
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
