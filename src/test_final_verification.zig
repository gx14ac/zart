const std = @import("std");
const print = std.debug.print;
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;

/// Helper function like Go BART's mpp
fn mpp(prefix_str: []const u8) Prefix {
    if (std.mem.eql(u8, prefix_str, "192.168.0.1/32")) {
        return Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 1 } }, 32).masked();
    } else if (std.mem.eql(u8, prefix_str, "192.168.0.2/32")) {
        return Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 2 } }, 32).masked();
    } else if (std.mem.eql(u8, prefix_str, "192.168.0.0/26")) {
        return Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 0 } }, 26).masked();
    } else if (std.mem.eql(u8, prefix_str, "10.0.0.0/27")) {
        return Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 27).masked();
    }
    // Default fallback
    return Prefix.init(&IPAddr{ .v4 = .{ 0, 0, 0, 0 } }, 0).masked();
}

/// Test route structure like Go BART
const TableTest = struct {
    addr: []const u8,
    want: i32,
};

/// Check routes like Go BART's checkRoutes
fn checkRoutes(table: *Table(i32), tests: []const TableTest) !bool {
    for (tests) |test_case| {
        const addr = parseAddr(test_case.addr);
        const result = table.lookup(&addr);
        
        if (!result.ok and test_case.want != -1) {
            print("ERROR: Lookup {s} got (_, false), want ({}, true)\n", .{ test_case.addr, test_case.want });
            return false;
        }
        if (result.ok and result.value != test_case.want) {
            print("ERROR: Lookup {s} got ({}, true), want ({}, true)\n", .{ test_case.addr, result.value, test_case.want });
            return false;
        }
    }
    return true;
}

/// Parse IP address
fn parseAddr(addr_str: []const u8) IPAddr {
    if (std.mem.eql(u8, addr_str, "192.168.0.1")) {
        return IPAddr{ .v4 = .{ 192, 168, 0, 1 } };
    } else if (std.mem.eql(u8, addr_str, "192.168.0.2")) {
        return IPAddr{ .v4 = .{ 192, 168, 0, 2 } };
    } else if (std.mem.eql(u8, addr_str, "192.168.0.3")) {
        return IPAddr{ .v4 = .{ 192, 168, 0, 3 } };
    } else if (std.mem.eql(u8, addr_str, "192.168.0.255")) {
        return IPAddr{ .v4 = .{ 192, 168, 0, 255 } };
    } else if (std.mem.eql(u8, addr_str, "192.168.1.1")) {
        return IPAddr{ .v4 = .{ 192, 168, 1, 1 } };
    } else if (std.mem.eql(u8, addr_str, "10.0.0.5")) {
        return IPAddr{ .v4 = .{ 10, 0, 0, 5 } };
    }
    return IPAddr{ .v4 = .{ 0, 0, 0, 0 } };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== ZART vs Go BART TestInsert Verification ===\n", .{});
    
    var tbl = Table(i32).init(allocator);
    defer tbl.deinit();
    
    // Go BART TestInsert exact sequence
    print("Step 1: Create a new leaf strideTable, with compressed path\n", .{});
    tbl.insert(&mpp("192.168.0.1/32"), 1);
    
    const test1 = [_]TableTest{
        .{ .addr = "192.168.0.1", .want = 1 },
        .{ .addr = "192.168.0.2", .want = -1 },
        .{ .addr = "192.168.0.3", .want = -1 },
        .{ .addr = "192.168.0.255", .want = -1 },
        .{ .addr = "192.168.1.1", .want = -1 },
        .{ .addr = "10.0.0.5", .want = -1 },
    };
    
    if (try checkRoutes(&tbl, &test1)) {
        print("✅ Step 1 passed\n", .{});
    } else {
        print("❌ Step 1 failed\n", .{});
        return;
    }
    
    print("\nStep 2: explode path compressed\n", .{});
    tbl.insert(&mpp("192.168.0.2/32"), 2);
    
    const test2 = [_]TableTest{
        .{ .addr = "192.168.0.1", .want = 1 },
        .{ .addr = "192.168.0.2", .want = 2 },
        .{ .addr = "192.168.0.3", .want = -1 },
        .{ .addr = "192.168.0.255", .want = -1 },
        .{ .addr = "192.168.1.1", .want = -1 },
        .{ .addr = "10.0.0.5", .want = -1 },
    };
    
    if (try checkRoutes(&tbl, &test2)) {
        print("✅ Step 2 passed\n", .{});
    } else {
        print("❌ Step 2 failed\n", .{});
        return;
    }
    
    print("\nStep 3: Insert into existing leaf (THE CRITICAL TEST)\n", .{});
    tbl.insert(&mpp("192.168.0.0/26"), 7);
    
    const test3 = [_]TableTest{
        .{ .addr = "192.168.0.1", .want = 1 },
        .{ .addr = "192.168.0.2", .want = 2 },
        .{ .addr = "192.168.0.3", .want = 7 },  // ← CRITICAL: Go BART expects 7
        .{ .addr = "192.168.0.255", .want = -1 },
        .{ .addr = "192.168.1.1", .want = -1 },
        .{ .addr = "10.0.0.5", .want = -1 },
    };
    
    if (try checkRoutes(&tbl, &test3)) {
        print("✅ Step 3 passed - 192.168.0.3 correctly returns 7!\n", .{});
    } else {
        print("❌ Step 3 failed - CRITICAL DIFFERENCE FROM Go BART\n", .{});
        return;
    }
    
    print("\n🎉 ZART PERFECTLY MATCHES Go BART's TestInsert behavior!\n", .{});
    print("192.168.0.3 correctly returns value=7 after inserting 192.168.0.0/26\n", .{});
} 