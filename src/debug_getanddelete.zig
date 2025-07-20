const std = @import("std");
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;

// randomPrefixes function from zart_benchmark.zig
fn randomPrefixes(allocator: std.mem.Allocator, count: usize) ![]Prefix {
    const prefixes = try allocator.alloc(Prefix, count);
    for (prefixes) |*pfx| {
        const is_v6 = std.crypto.random.boolean(); // 50% chance for IPv6
        if (is_v6) {
            // IPv6 prefix
            var addr_bytes: [16]u8 = undefined;
            std.crypto.random.bytes(&addr_bytes);
            const addr = IPAddr{ .v6 = addr_bytes };
            const bits = std.crypto.random.intRangeAtMost(u8, 8, 128);
            pfx.* = Prefix.init(&addr, bits);
        } else {
            // IPv4 prefix
            var addr_bytes: [4]u8 = undefined;
            std.crypto.random.bytes(&addr_bytes);
            const addr = IPAddr{ .v4 = addr_bytes };
            const bits = std.crypto.random.intRangeAtMost(u8, 8, 32);
            pfx.* = Prefix.init(&addr, bits);
        }
    }
    return prefixes;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🔍 **Debug GetAndDelete Issue**\n", .{});
    std.debug.print("================================\n\n", .{});

    var table = Table(i32).init(allocator);
    defer table.deinit();

    // より小さなセットでテスト（デバッグ用）
    std.debug.print("Step 1: Creating small test set...\n", .{});
    const test_count = 10;
    const prefixes = try randomPrefixes(allocator, test_count);
    defer allocator.free(prefixes);

    std.debug.print("Step 2: Inserting {} prefixes...\n", .{test_count});
    for (prefixes, 0..) |*pfx, i| {
        table.insert(pfx, @as(i32, @intCast(i)));
        std.debug.print("  Inserted {}: ", .{i});
        if (pfx.addr.is4()) {
            const v4 = pfx.addr.v4;
            std.debug.print("{}.{}.{}.{}/{}\n", .{ v4[0], v4[1], v4[2], v4[3], pfx.bits });
        } else {
            std.debug.print("IPv6/{}\n", .{pfx.bits});
        }
    }
    
    std.debug.print("Table size after insert: {}\n", .{table.size()});

    std.debug.print("\nStep 3: Testing get operations before delete...\n", .{});
    for (prefixes, 0..) |*pfx, i| {
        const get_result = table.get(pfx);
        std.debug.print("  Get[{}]: ", .{i});
        if (get_result) |val| {
            std.debug.print("found value={}\n", .{val});
        } else {
            std.debug.print("NOT FOUND\n", .{});
        }
    }

    std.debug.print("\nStep 4: Testing getAndDelete operations...\n", .{});
    for (prefixes, 0..) |*pfx, i| {
        std.debug.print("\n  Testing prefix {}: ", .{i});
        if (pfx.addr.is4()) {
            const v4 = pfx.addr.v4;
            std.debug.print("{}.{}.{}.{}/{}\n", .{ v4[0], v4[1], v4[2], v4[3], pfx.bits });
        } else {
            std.debug.print("IPv6/{}\n", .{pfx.bits});
        }
        
        // First get to see what should be there
        const want = table.get(pfx);
        std.debug.print("    Pre-delete get: ");
        if (want) |val| {
            std.debug.print("found value={}\n", .{val});
        } else {
            std.debug.print("NOT FOUND\n", .{});
        }
        
        // Now getAndDelete
        const result = table.getAndDelete(pfx);
        std.debug.print("    GetAndDelete: ");
        if (result.ok) {
            std.debug.print("success, value={}\n", .{result.value});
        } else {
            std.debug.print("FAILED\n", .{});
            if (want) |expected| {
                std.debug.print("    ERROR: Expected value={}, but got failure\n", .{expected});
                return error.TestFailure;
            }
        }
        
        // Verify it was actually deleted
        const verify = table.get(pfx);
        std.debug.print("    Post-delete get: ");
        if (verify) |val| {
            std.debug.print("ERROR: still found value={}\n", .{val});
            return error.TestFailure;
        } else {
            std.debug.print("correctly deleted\n", .{});
        }
        
        std.debug.print("    Table size: {}\n", .{table.size()});
    }

    std.debug.print("\n✅ Debug completed successfully!\n", .{});
} 