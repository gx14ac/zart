const std = @import("std");
const print = std.debug.print;
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const check = gpa.deinit();
        if (check == .leak) {
            print("⚠️ Memory leaks detected!\n", .{});
        } else {
            print("✅ No memory leaks\n", .{});
        }
    }
    const allocator = gpa.allocator();

    print("=== Simple Large Scale Test ===\n", .{});
    
    // Test 1: 基本挿入・検索 (5,000件)
    print("1. Testing 5,000 prefixes insertion...\n", .{});
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    
    for (0..5000) |i| {
        // IPv4プレフィックス生成
        const a = rand.int(u8);
        const b = rand.int(u8); 
        const c = rand.int(u8);
        const d = rand.int(u8);
        const bits = 8 + rand.int(u8) % 25;
        
        const addr = IPAddr{ .v4 = .{ a, b, c, d } };
        const prefix = Prefix.init(&addr, @as(u8, @intCast(bits))).masked();
        
        table.insert(&prefix, @as(i32, @intCast(i)));
        
        if ((i + 1) % 1000 == 0) {
            print("  Inserted {} prefixes, table size: {}\n", .{ i + 1, table.size() });
        }
    }
    
    print("✅ Insertion completed! Total size: {}\n", .{table.size()});
    
    // Test 2: ランダム検索
    print("2. Testing random lookups...\n", .{});
    var found_count: usize = 0;
    
    for (0..1000) |_| {
        const a = rand.int(u8);
        const b = rand.int(u8);
        const c = rand.int(u8);
        const d = rand.int(u8);
        
        const test_addr = IPAddr{ .v4 = .{ a, b, c, d } };
        const result = table.lookup(&test_addr);
        
        if (result.ok) {
            found_count += 1;
        }
    }
    
    print("✅ Random lookup completed! Found {} out of 1000 lookups\n", .{found_count});
    
    // Test 3: Persistentクローン
    print("3. Testing persistent clone...\n", .{});
    var clone = table.clone();
    defer clone.deinitPersistent();
    
    if (clone.size() != table.size()) {
        print("❌ Clone size mismatch: original {}, clone {}\n", .{ table.size(), clone.size() });
        return;
    }
    
    print("✅ Clone test completed! Clone size: {}\n", .{clone.size()});
    
    print("\n🎉 All tests passed successfully!\n", .{});
} 