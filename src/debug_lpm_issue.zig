const std = @import("std");
const bart = @import("main.zig");
const print = std.debug.print;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== 192.168.0.3 LPM Debug Test ===\n", .{});

    var table = bart.Table(i32).init(allocator);
    defer table.deinit();

    // Test 1: 192.168.0.1/32 のみ
    print("\n1. Insert 192.168.0.1/32 -> 1\n", .{});
    table.insert(&bart.Prefix.parse("192.168.0.1/32"), 1);
    
    // 192.168.0.3 を検索
    const addr3 = bart.IPAddr.parse("192.168.0.3");
    const lookup1 = table.lookup(&addr3);
    print("   192.168.0.3 lookup: ok={}, value={}\n", .{lookup1.ok, if (lookup1.ok) lookup1.value else -1});
    
    // Test 2: 192.168.0.2/32 を追加
    print("\n2. Insert 192.168.0.2/32 -> 2\n", .{});
    table.insert(&bart.Prefix.parse("192.168.0.2/32"), 2);
    
    // 192.168.0.3 を再検索
    const lookup2 = table.lookup(&addr3);
    print("   192.168.0.3 lookup: ok={}, value={}\n", .{lookup2.ok, if (lookup2.ok) lookup2.value else -1});
    
    // 詳細なデバッグ情報
    print("\n=== Debug Info ===\n", .{});
    print("Table size: {}\n", .{table.size()});
    
    // 各アドレスを確認
    const addr1 = bart.IPAddr.parse("192.168.0.1");
    const addr2 = bart.IPAddr.parse("192.168.0.2");
    
    const lookup_addr1 = table.lookup(&addr1);
    const lookup_addr2 = table.lookup(&addr2);
    
    print("192.168.0.1 lookup: ok={}, value={}\n", .{lookup_addr1.ok, if (lookup_addr1.ok) lookup_addr1.value else -1});
    print("192.168.0.2 lookup: ok={}, value={}\n", .{lookup_addr2.ok, if (lookup_addr2.ok) lookup_addr2.value else -1});
    
    // Test 3: 192.168.0.0/26 を追加
    print("\n3. Insert 192.168.0.0/26 -> 7\n", .{});
    table.insert(&bart.Prefix.parse("192.168.0.0/26"), 7);
    
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
        const test_addr = bart.IPAddr.parse(addr_str);
        const test_lookup = table.lookup(&test_addr);
        print("   {} lookup: ok={}, value={}\n", .{addr_str, test_lookup.ok, if (test_lookup.ok) test_lookup.value else -1});
    }
} 