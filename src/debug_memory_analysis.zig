const std = @import("std");
const print = std.debug.print;
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;

/// 大規模テストでのメモリ問題を段階的に分析
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .verbose_log = true,
        .enable_memory_limit = true,
        .never_unmap = true, // デバッグ用：解放メモリを保持
    }){};
    defer {
        const check = gpa.deinit();
        if (check == .leak) {
            print("⚠️ Memory leaks detected!\n", .{});
        } else {
            print("✅ No memory leaks\n", .{});
        }
    }
    const allocator = gpa.allocator();

    print("=== Memory Analysis for Large Scale Tests ===\n", .{});
    
    // Step 1: 小規模テスト（100件）
    print("\n1. Small scale test (100 prefixes):\n", .{});
    try testMemoryUsage(allocator, 100);
    
    // Step 2: 中規模テスト（1,000件）
    print("\n2. Medium scale test (1,000 prefixes):\n", .{});
    try testMemoryUsage(allocator, 1000);
    
    // Step 3: 大規模テスト（5,000件）- 段階的に増加
    print("\n3. Large scale test (5,000 prefixes):\n", .{});
    try testMemoryUsage(allocator, 5000);
    
    // Step 4: 極大規模テスト（10,000件）
    print("\n4. Extra large scale test (10,000 prefixes):\n", .{});
    try testMemoryUsage(allocator, 10000);
}

fn testMemoryUsage(allocator: std.mem.Allocator, count: usize) !void {
    print("  Testing with {} prefixes...\n", .{count});
    
    // メモリ使用量測定開始
    const start_memory = try getCurrentMemoryUsage();
    
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    // ランダムプレフィックス生成
    const prefixes = try generateTestPrefixes(allocator, count);
    defer allocator.free(prefixes);
    
    // 挿入
    for (prefixes, 0..) |*pfx, i| {
        table.insert(pfx, @as(i32, @intCast(i)));
        
        // 1000件毎にメモリ使用量チェック
        if ((i + 1) % 1000 == 0) {
            const current_memory = try getCurrentMemoryUsage();
            print("    After {} inserts: {} KB\n", .{ i + 1, (current_memory - start_memory) / 1024 });
        }
    }
    
    print("    Total table size: {} (IPv4: {}, IPv6: {})\n", .{ table.size(), table.size4, table.size6 });
    
    // 終了メモリ使用量
    const end_memory = try getCurrentMemoryUsage();
    print("    Memory used: {} KB\n", .{(end_memory - start_memory) / 1024});
    
    print("    ✅ Test completed successfully\n", .{});
}

fn generateTestPrefixes(allocator: std.mem.Allocator, count: usize) ![]Prefix {
    var prng = std.Random.DefaultPrng.init(42); // 固定シード
    const rand = prng.random();
    
    const prefixes = try allocator.alloc(Prefix, count);
    
    for (prefixes, 0..) |*pfx, i| {
        if (i % 2 == 0) {
            // IPv4
            const a = rand.int(u8);
            const b = rand.int(u8);
            const c = rand.int(u8);
            const d = rand.int(u8);
            const bits = 8 + rand.int(u8) % 25; // /8 から /32
            const addr = IPAddr{ .v4 = .{ a, b, c, d } };
            pfx.* = Prefix.init(&addr, @as(u8, @intCast(bits))).masked();
        } else {
            // IPv6 (簡略版)
            var ipv6: [16]u8 = undefined;
            rand.bytes(&ipv6);
            const bits = 16 + rand.int(u8) % 113; // /16 から /128
            const addr = IPAddr{ .v6 = ipv6 };
            pfx.* = Prefix.init(&addr, @as(u8, @intCast(bits))).masked();
        }
    }
    
    return prefixes;
}

fn getCurrentMemoryUsage() !usize {
    // macOS: 実際のメモリ使用量取得は難しいので、概算値を返す
    // 実装を簡単にするため、固定値を返す
    return 0; // TODO: 実際のメモリ測定実装
} 