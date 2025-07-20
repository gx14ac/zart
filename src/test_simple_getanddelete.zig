const std = @import("std");
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;

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
    
    // Simple IPv4 parsing
    var parts: [4]u8 = undefined;
    var iter = std.mem.splitScalar(u8, addr_str, '.');
    var i: usize = 0;

    while (iter.next()) |part| {
        if (i >= 4) std.debug.panic("Invalid IPv4: {s}\n", .{addr_str});
        parts[i] = std.fmt.parseInt(u8, part, 10) catch std.debug.panic("Invalid IPv4 part: {s}\n", .{part});
        i += 1;
    }

    if (i != 4) std.debug.panic("Invalid IPv4: {s}\n", .{addr_str});
    
    const addr = IPAddr{ .v4 = parts };
    const prefix = Prefix.init(&addr, prefix_len);
    return prefix.masked();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🧪 **Simple GetAndDelete Test**\n", .{});
    std.debug.print("=================================\n\n", .{});

    var table = Table(i32).init(allocator);
    defer table.deinit();

    // Insert known prefixes
    const test_prefixes = [_]struct {
        prefix: []const u8,
        value: i32,
    }{
        .{ .prefix = "10.0.0.0/8", .value = 1 },
        .{ .prefix = "192.168.1.0/24", .value = 2 },
        .{ .prefix = "172.16.0.1/32", .value = 3 },
        .{ .prefix = "203.0.113.0/24", .value = 4 },
        .{ .prefix = "198.51.100.0/24", .value = 5 },
    };

    std.debug.print("Step 1: Inserting {} test prefixes...\n", .{test_prefixes.len});
    for (test_prefixes) |test_case| {
        const pfx = mpp(test_case.prefix);
        table.insert(&pfx, test_case.value);
        std.debug.print("  Inserted: {s} -> {}\n", .{ test_case.prefix, test_case.value });
    }
    
    std.debug.print("Table size after inserts: {}\n\n", .{table.size()});

    std.debug.print("Step 2: Testing GetAndDelete...\n", .{});
    for (test_prefixes) |test_case| {
        const pfx = mpp(test_case.prefix);
        
        std.debug.print("  Testing prefix: {s}\n", .{test_case.prefix});
        
        // Verify it exists first
        const pre_get = table.get(&pfx);
        std.debug.print("    Pre-delete get: ", .{});
        if (pre_get) |val| {
            std.debug.print("found value={}\n", .{val});
            if (val != test_case.value) {
                std.debug.print("    ERROR: Wrong value! Expected {}, got {}\n", .{ test_case.value, val });
                return error.TestFailure;
            }
        } else {
            std.debug.print("NOT FOUND\n", .{});
            std.debug.print("    ERROR: Prefix should exist!\n", .{});
            return error.TestFailure;
        }
        
        // GetAndDelete
        const result = table.getAndDelete(&pfx);
        std.debug.print("    GetAndDelete: ", .{});
        if (result.ok) {
            std.debug.print("success, value={}\n", .{result.value});
            if (result.value != test_case.value) {
                std.debug.print("    ERROR: Wrong value! Expected {}, got {}\n", .{ test_case.value, result.value });
                return error.TestFailure;
            }
        } else {
            std.debug.print("FAILED\n", .{});
            std.debug.print("    ERROR: GetAndDelete should have succeeded!\n", .{});
            return error.TestFailure;
        }
        
        // Verify it's gone
        const post_get = table.get(&pfx);
        std.debug.print("    Post-delete get: ", .{});
        if (post_get) |val| {
            std.debug.print("ERROR: still found value={}\n", .{val});
            std.debug.print("    ERROR: Prefix should have been deleted!\n", .{});
            return error.TestFailure;
        } else {
            std.debug.print("correctly deleted\n", .{});
        }
        
        std.debug.print("    Table size: {}\n", .{table.size()});
        
        // Test GetAndDelete again (should fail)
        const second_result = table.getAndDelete(&pfx);
        if (second_result.ok) {
            std.debug.print("    ERROR: Second GetAndDelete should have failed!\n", .{});
            return error.TestFailure;
        }
        std.debug.print("    Second GetAndDelete correctly failed\n", .{});
        
        std.debug.print("\n", .{});
    }

    std.debug.print("Final table size: {}\n", .{table.size()});
    if (table.size() != 0) {
        std.debug.print("ERROR: Table should be empty after all deletions!\n", .{});
        return error.TestFailure;
    }

    std.debug.print("✅ Simple GetAndDelete test passed!\n", .{});
} 