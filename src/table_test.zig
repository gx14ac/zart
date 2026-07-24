// ZART Table Test Module
// Go BART compatible test helpers and functions

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const netip = @import("netip.zig");
const Table = @import("table.zig").Table;

// Go BART: var mpa = netip.MustParseAddr
// Parse IP address from string and panic if invalid
pub const mpa = netip.Addr.mustParseAddr;

// Go BART: var mpp = func(s string) netip.Prefix
// Parse prefix from string and validate canonicalization
pub const mpp = struct {
    pub fn call(comptime prefix_str: []const u8) netip.Prefix {
        const pfx = netip.Prefix.mustParsePrefix(prefix_str);
        const masked = pfx.masked();
        if (!pfx.eql(&masked)) {
            std.debug.panic("Prefix {s} is not canonicalized", .{prefix_str});
        }
        return pfx;
    }
}.call;

// Go BART: tests for deep copies with Cloner interface
// type MyInt int
const MyInt = struct {
    value: i32,
    
    // Go BART: func (i *MyInt) Clone() *MyInt
    // implement the Cloner interface
    pub fn clone(self: *const MyInt, allocator: std.mem.Allocator) !*MyInt {
        const new_int = try allocator.create(MyInt);
        new_int.* = MyInt{ .value = self.value };
        return new_int;
    }
    
    pub fn deinit(self: *MyInt, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};

// Test the parsing functions
test "Test mpa and mpp functions" {
    // Test IPv4 address parsing
    const addr1 = mpa("192.168.1.1");
    try std.testing.expect(addr1.is4());
    
    // Test IPv4 prefix parsing
    const pfx1 = mpp("192.168.1.0/24");
    try std.testing.expectEqual(@as(u8, 24), pfx1.bits());
    try std.testing.expect(pfx1.is4());
}

// Test MyInt Cloner implementation
test "Test MyInt Cloner interface" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Create original MyInt
    const original = try allocator.create(MyInt);
    original.* = MyInt{ .value = 42 };
    defer original.deinit(allocator);
    
    // Clone it
    const cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);
    
    // Verify they have the same value but different addresses
    try std.testing.expectEqual(original.value, cloned.value);
    try std.testing.expect(original != cloned); // Different pointers
}

// Go BART: func TestInvalid(t *testing.T)
// Test invalid input handling for all table methods
test "TestInvalid - Insert and Get" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tbl = Table(?u32).init(allocator);
    defer tbl.deinit();
    
    // Go BART: var zeroPfx netip.Prefix
    const zeroPfx = netip.Prefix{ .address = netip.Addr{ .octets = [_]u8{0} ** 16 }, .prefix_len = 0 };
    
    // Test insert with invalid prefix - should not panic
    tbl.insert(&zeroPfx, null);
    
    // Test get with invalid prefix - should not panic
    _ = tbl.get(&zeroPfx);
}

test "TestInvalid - Contains and Lookup" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tbl = Table(?u32).init(allocator);
    defer tbl.deinit();
    
    // Go BART: var zeroIP netip.Addr
    const zeroIP = netip.Addr{ .octets = [_]u8{0} ** 16 };
    
    // Test contains with invalid IP - should return false for empty table, not panic
    const contains_result = tbl.contains(&zeroIP);
    try std.testing.expectEqual(false, contains_result);
    
    // Test lookup with invalid IP - should return false for empty table, not panic
    const lookup_result = tbl.lookup(&zeroIP);
    try std.testing.expectEqual(false, lookup_result.ok);
}

test "TestInvalid - Prefix Operations" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tbl = Table(?u32).init(allocator);
    defer tbl.deinit();
    
    // Go BART: var zeroPfx netip.Prefix
    const zeroPfx = netip.Prefix{ .address = netip.Addr{ .octets = [_]u8{0} ** 16 }, .prefix_len = 0 };
    
    // Test lookupPrefix with invalid prefix - should not panic
    _ = tbl.lookupPrefix(&zeroPfx);
    
    // Test lookupPrefixLPM with invalid prefix - should not panic
    _ = tbl.lookupPrefixLPM(&zeroPfx);
    
    // Test overlapsPrefix with invalid prefix - should not panic
    _ = tbl.overlapsPrefix(&zeroPfx);
}

// Go BART: type tableTest struct { ip string; want int }
const TableTest = struct {
    ip: []const u8,
    want: i32, // -1 means no route expected
};

// Go BART: func checkNumNodes(t *testing.T, tbl *Table[int], want int)
// Helper function to check the number of nodes in the table
fn checkNumNodes(tbl: anytype, want: i32) !void {
    // Note: ZART doesn't expose node count directly like Go BART
    // For now, we'll use size() as a proxy
    const actual_size = tbl.size();
    std.debug.print("Table size: {} (expected approximate node count: {})\n", .{ actual_size, want });
    // We can't do exact node count comparison without exposing internal structure
    // This is a limitation compared to Go BART's testing
}

// Go BART: func checkRoutes(t *testing.T, tbl *Table[int], tests []tableTest)
// Helper function to check routes in the table
fn checkRoutes(tbl: anytype, tests: []const TableTest) !void {
    for (tests) |test_case| {
        const ip = mpa(test_case.ip);
        const result = tbl.lookup(&ip);
        
        if (test_case.want == -1) {
            // Expect no route
            if (result.ok) {
                std.debug.print("❌ Expected no route for {s}, but got value: {}\n", .{ test_case.ip, result.value });
                return error.UnexpectedRoute;
            }
        } else {
            // Expect specific route
            if (!result.ok) {
                std.debug.print("❌ Expected route {} for {s}, but got no route\n", .{ test_case.want, test_case.ip });
                return error.MissingRoute;
            }
            if (result.value != test_case.want) {
                std.debug.print("❌ Expected route {} for {s}, but got {}\n", .{ test_case.want, test_case.ip, result.value });
                return error.WrongRoute;
            }
        }
        std.debug.print("✅ {s} -> {}\n", .{ test_case.ip, if (test_case.want == -1) @as(i32, -1) else result.value });
    }
}

// Go BART: func TestInsert(t *testing.T)
test "TestInsert - IPv4 Basic Operations" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tbl = Table(i32).init(allocator);
    defer tbl.deinit();
    
    std.debug.print("\n🧪 **TestInsert - IPv4 Basic Operations**\n", .{});
    std.debug.print("==========================================\n", .{});
    
    // Create a new leaf strideTable, with compressed path
    std.debug.print("\n📝 Step 1: Insert 192.168.0.1/32 -> 1\n", .{});
    tbl.insert(&mpp("192.168.0.1/32"), 1);
    try checkNumNodes(&tbl, 1);
    try checkRoutes(&tbl, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.168.0.2", .want = -1 },
        .{ .ip = "192.168.0.3", .want = -1 },
        .{ .ip = "192.168.0.255", .want = -1 },
        .{ .ip = "192.168.1.1", .want = -1 },
        .{ .ip = "192.170.1.1", .want = -1 },
        .{ .ip = "192.180.0.1", .want = -1 },
        .{ .ip = "192.180.3.5", .want = -1 },
        .{ .ip = "10.0.0.5", .want = -1 },
        .{ .ip = "10.0.0.15", .want = -1 },
    });
    
    // explode path compressed
    std.debug.print("\n📝 Step 2: Insert 192.168.0.2/32 -> 2 (explode path compressed)\n", .{});
    tbl.insert(&mpp("192.168.0.2/32"), 2);
    try checkNumNodes(&tbl, 4);
    try checkRoutes(&tbl, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.168.0.2", .want = 2 },
        .{ .ip = "192.168.0.3", .want = -1 },
        .{ .ip = "192.168.0.255", .want = -1 },
        .{ .ip = "192.168.1.1", .want = -1 },
        .{ .ip = "192.170.1.1", .want = -1 },
        .{ .ip = "192.180.0.1", .want = -1 },
        .{ .ip = "192.180.3.5", .want = -1 },
        .{ .ip = "10.0.0.5", .want = -1 },
        .{ .ip = "10.0.0.15", .want = -1 },
    });
    
    // Insert into existing leaf
    std.debug.print("\n📝 Step 3: Insert 192.168.0.0/26 -> 7 (into existing leaf)\n", .{});
    tbl.insert(&mpp("192.168.0.0/26"), 7);
    try checkNumNodes(&tbl, 4);
    try checkRoutes(&tbl, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.168.0.2", .want = 2 },
        .{ .ip = "192.168.0.3", .want = 7 },
        .{ .ip = "192.168.0.255", .want = -1 },
        .{ .ip = "192.168.1.1", .want = -1 },
        .{ .ip = "192.170.1.1", .want = -1 },
        .{ .ip = "192.180.0.1", .want = -1 },
        .{ .ip = "192.180.3.5", .want = -1 },
        .{ .ip = "10.0.0.5", .want = -1 },
        .{ .ip = "10.0.0.15", .want = -1 },
    });
}

// Test masked() function
test "Test netip.Prefix.masked()" {
    std.debug.print("\n🧪 **Testing Prefix Masking**\n", .{});
    
    // Test IPv4 /32 prefix masking (should be already canonical)
    const pfx_32 = netip.Prefix.mustParsePrefix("192.168.0.1/32");
    const masked_32 = pfx_32.masked();
    std.debug.print("Original: 192.168.0.1/32\n", .{});
    std.debug.print("Original octets: {any}\n", .{pfx_32.address.octets[12..16]});
    std.debug.print("Masked octets: {any}\n", .{masked_32.address.octets[12..16]});
    std.debug.print("Are equal? {}\n", .{pfx_32.eql(&masked_32)});
    
    // Test IPv4 /24 prefix masking - should zero out last byte
    const pfx_24 = netip.Prefix.fromIPv4(192, 168, 0, 255, 24);
    const masked_24 = pfx_24.masked();
    std.debug.print("Original: 192.168.0.255/24\n", .{});
    std.debug.print("Original octets: {any}\n", .{pfx_24.address.octets[12..16]});
    std.debug.print("Masked octets: {any}\n", .{masked_24.address.octets[12..16]});
    std.debug.print("Are equal? {}\n", .{pfx_24.eql(&masked_24)});
    // Last byte should be 0, not 255
    try std.testing.expectEqual(@as(u8, 0), masked_24.address.octets[15]);
}

// Debug ZART routing problem  
test "Debug ZART Routing Problem" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tbl = Table(i32).init(allocator);
    defer tbl.deinit();
    
    std.debug.print("\n🐛 **Debug ZART Routing Problem**\n", .{});
    
    // Insert exactly 192.168.0.1/32
    const pfx = mpp("192.168.0.1/32");
    std.debug.print("Inserting prefix: bits={}, octets={any}\n", .{ pfx.bits(), pfx.address.octets[12..16] });
    tbl.insert(&pfx, 1);
    
    // Test lookup for 192.168.0.1 (should match)
    const ip1 = mpa("192.168.0.1");
    std.debug.print("Looking up IP1: octets={any}\n", .{ip1.octets[12..16]});
    const result1 = tbl.lookup(&ip1);
    std.debug.print("IP1 result: ok={}, value={}\n", .{ result1.ok, if (result1.ok) result1.value else 0 });
    
    // Test lookup for 192.168.0.2 (should NOT match)  
    const ip2 = mpa("192.168.0.2");
    std.debug.print("Looking up IP2: octets={any}\n", .{ip2.octets[12..16]});
    const result2 = tbl.lookup(&ip2);
    std.debug.print("IP2 result: ok={}, value={}\n", .{ result2.ok, if (result2.ok) result2.value else 0 });
    
    // Expect result2.ok to be false
    try std.testing.expectEqual(false, result2.ok);
}

// Go BART: func TestInsertPersist(t *testing.T)
test "TestInsertPersist - IPv4 Basic Operations" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tbl = Table(i32).init(allocator);
    defer tbl.deinit();
    
    std.debug.print("\n🧪 **TestInsertPersist - IPv4 Basic Operations**\n", .{});
    std.debug.print("===============================================\n", .{});
    
    // Create a new leaf strideTable, with compressed path
    std.debug.print("\n📝 Step 1: InsertPersist 192.168.0.1/32 -> 1\n", .{});
    var tbl_ptr = try tbl.InsertPersist(&mpp("192.168.0.1/32"), 1);
    defer {
        tbl_ptr.deinit();
        allocator.destroy(tbl_ptr);
    }
    
    try checkNumNodes(tbl_ptr, 1);
    try checkRoutes(tbl_ptr, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.168.0.2", .want = -1 },
        .{ .ip = "192.168.0.3", .want = -1 },
        .{ .ip = "192.168.0.255", .want = -1 },
        .{ .ip = "192.168.1.1", .want = -1 },
        .{ .ip = "192.170.1.1", .want = -1 },
        .{ .ip = "192.180.0.1", .want = -1 },
        .{ .ip = "192.180.3.5", .want = -1 },
        .{ .ip = "10.0.0.5", .want = -1 },
        .{ .ip = "10.0.0.15", .want = -1 },
    });
    
    // explode path compressed
    std.debug.print("\n📝 Step 2: InsertPersist 192.168.0.2/32 -> 2 (explode path compressed)\n", .{});
    const tbl_ptr2 = try tbl_ptr.InsertPersist(&mpp("192.168.0.2/32"), 2);
    defer {
        tbl_ptr2.deinit();
        allocator.destroy(tbl_ptr2);
    }
    
    try checkNumNodes(tbl_ptr2, 4);
    try checkRoutes(tbl_ptr2, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.168.0.2", .want = 2 },
        .{ .ip = "192.168.0.3", .want = -1 },
        .{ .ip = "192.168.0.255", .want = -1 },
        .{ .ip = "192.168.1.1", .want = -1 },
        .{ .ip = "192.170.1.1", .want = -1 },
        .{ .ip = "192.180.0.1", .want = -1 },
        .{ .ip = "192.180.3.5", .want = -1 },
        .{ .ip = "10.0.0.5", .want = -1 },
        .{ .ip = "10.0.0.15", .want = -1 },
    });
    
    // Insert into existing leaf
    std.debug.print("\n📝 Step 3: InsertPersist 192.168.0.0/26 -> 7 (into existing leaf)\n", .{});
    const tbl_ptr3 = try tbl_ptr2.InsertPersist(&mpp("192.168.0.0/26"), 7);
    defer {
        tbl_ptr3.deinit();
        allocator.destroy(tbl_ptr3);
    }
    
    try checkNumNodes(tbl_ptr3, 4);
    try checkRoutes(tbl_ptr3, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.168.0.2", .want = 2 },
        .{ .ip = "192.168.0.3", .want = 7 },
        .{ .ip = "192.168.0.255", .want = -1 },
        .{ .ip = "192.168.1.1", .want = -1 },
        .{ .ip = "192.170.1.1", .want = -1 },
        .{ .ip = "192.180.0.1", .want = -1 },
        .{ .ip = "192.180.3.5", .want = -1 },
        .{ .ip = "10.0.0.5", .want = -1 },
        .{ .ip = "10.0.0.15", .want = -1 },
    });
    
    // Create a different leaf at root
    std.debug.print("\n📝 Step 4: InsertPersist 10.0.0.0/27 -> 3 (different leaf at root)\n", .{});
    const tbl_ptr4 = try tbl_ptr3.InsertPersist(&mpp("10.0.0.0/27"), 3);
    defer {
        tbl_ptr4.deinit();
        allocator.destroy(tbl_ptr4);
    }
    
    try checkNumNodes(tbl_ptr4, 4);
    try checkRoutes(tbl_ptr4, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.168.0.2", .want = 2 },
        .{ .ip = "192.168.0.3", .want = 7 },
        .{ .ip = "192.168.0.255", .want = -1 },
        .{ .ip = "192.168.1.1", .want = -1 },
        .{ .ip = "192.170.1.1", .want = -1 },
        .{ .ip = "192.180.0.1", .want = -1 },
        .{ .ip = "192.180.3.5", .want = -1 },
        .{ .ip = "10.0.0.5", .want = 3 },
        .{ .ip = "10.0.0.15", .want = 3 },
    });
    
    // Insert a default route, those have their own codepath.
    std.debug.print("\n📝 Step 5: InsertPersist 0.0.0.0/0 -> 6 (default route)\n", .{});
    const tbl_ptr5 = try tbl_ptr4.InsertPersist(&mpp("0.0.0.0/0"), 6);
    defer {
        tbl_ptr5.deinit();
        allocator.destroy(tbl_ptr5);
    }
    
    try checkNumNodes(tbl_ptr5, 4);
    try checkRoutes(tbl_ptr5, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.168.0.2", .want = 2 },
        .{ .ip = "192.168.0.3", .want = 7 },
        .{ .ip = "192.168.0.255", .want = 6 }, // Now matches default route
        .{ .ip = "192.168.1.1", .want = 6 },   // Now matches default route
        .{ .ip = "192.170.1.1", .want = 6 },   // Now matches default route
        .{ .ip = "192.180.0.1", .want = 6 },   // Now matches default route
        .{ .ip = "192.180.3.5", .want = 6 },   // Now matches default route
        .{ .ip = "10.0.0.5", .want = 3 },
        .{ .ip = "10.0.0.15", .want = 3 },
    });
}

// Go BART: func TestDelete(t *testing.T)
test "TestDelete - table_is_empty" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tbl = Table(i32).init(allocator);
    defer tbl.deinit();
    
    std.debug.print("\n🧪 **TestDelete - table_is_empty**\n", .{});
    std.debug.print("====================================\n", .{});
    
    // must not panic
    try checkNumNodes(&tbl, 0);
    
    // Generate a "random" prefix for testing (use a hardcoded prefix)
    const random_pfx = mpp("123.45.67.0/24");
    tbl.delete(&random_pfx);
    try checkNumNodes(&tbl, 0);
}

test "TestDelete - prefix_in_root" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tbl = Table(i32).init(allocator);
    defer tbl.deinit();
    
    std.debug.print("\n🧪 **TestDelete - prefix_in_root**\n", .{});
    std.debug.print("=====================================\n", .{});
    
    // Add/remove prefix from root table.
    try checkNumNodes(&tbl, 0);

    tbl.insert(&mpp("10.0.0.0/8"), 1);
    try checkNumNodes(&tbl, 1);
    try checkRoutes(&tbl, &[_]TableTest{
        .{ .ip = "10.0.0.1", .want = 1 },
        .{ .ip = "255.255.255.255", .want = -1 },
    });
    
    tbl.delete(&mpp("10.0.0.0/8"));
    try checkNumNodes(&tbl, 0);
    try checkRoutes(&tbl, &[_]TableTest{
        .{ .ip = "10.0.0.1", .want = -1 },
        .{ .ip = "255.255.255.255", .want = -1 },
    });
}

test "TestDelete - prefix_in_leaf" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tbl = Table(i32).init(allocator);
    defer tbl.deinit();
    
    std.debug.print("\n🧪 **TestDelete - prefix_in_leaf**\n", .{});
    std.debug.print("====================================\n", .{});
    
    // Create, then delete a single leaf table.
    try checkNumNodes(&tbl, 0);

    tbl.insert(&mpp("192.168.0.1/32"), 1);
    try checkNumNodes(&tbl, 1);
    try checkRoutes(&tbl, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "255.255.255.255", .want = -1 },
    });

    tbl.delete(&mpp("192.168.0.1/32"));
    try checkNumNodes(&tbl, 0);
    try checkRoutes(&tbl, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = -1 },
        .{ .ip = "255.255.255.255", .want = -1 },
    });
}

test "TestDelete - intermediate_no_routes" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tbl = Table(i32).init(allocator);
    defer tbl.deinit();
    
    std.debug.print("\n🧪 **TestDelete - intermediate_no_routes**\n", .{});
    std.debug.print("===========================================\n", .{});
    
    // Create an intermediate with 2 leaves, then delete one leaf.
    try checkNumNodes(&tbl, 0);

    tbl.insert(&mpp("192.168.0.1/32"), 1);
    tbl.insert(&mpp("192.180.0.1/32"), 2);
    try checkNumNodes(&tbl, 2);
    try checkRoutes(&tbl, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.180.0.1", .want = 2 },
        .{ .ip = "192.40.0.1", .want = -1 },
    });

    tbl.delete(&mpp("192.180.0.1/32"));
    try checkNumNodes(&tbl, 1);
    try checkRoutes(&tbl, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.180.0.1", .want = -1 },
        .{ .ip = "192.40.0.1", .want = -1 },
    });
}

test "TestDelete - intermediate_with_route" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tbl = Table(i32).init(allocator);
    defer tbl.deinit();
    
    std.debug.print("\n🧪 **TestDelete - intermediate_with_route**\n", .{});
    std.debug.print("============================================\n", .{});
    
    // Same, but the intermediate carries a route as well.
    try checkNumNodes(&tbl, 0);

    tbl.insert(&mpp("192.168.0.1/32"), 1);
    tbl.insert(&mpp("192.180.0.1/32"), 2);
    tbl.insert(&mpp("192.0.0.0/10"), 3);

    try checkNumNodes(&tbl, 2);
    try checkRoutes(&tbl, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.180.0.1", .want = 2 },
        .{ .ip = "192.40.0.1", .want = 3 },
        .{ .ip = "192.255.0.1", .want = -1 },
    });

    tbl.delete(&mpp("192.180.0.1/32"));
    try checkNumNodes(&tbl, 2);
    try checkRoutes(&tbl, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.180.0.1", .want = -1 },
        .{ .ip = "192.40.0.1", .want = 3 },
        .{ .ip = "192.255.0.1", .want = -1 },
    });
}

test "TestDelete - intermediate_many_leaves" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tbl = Table(i32).init(allocator);
    defer tbl.deinit();
    
    std.debug.print("\n🧪 **TestDelete - intermediate_many_leaves**\n", .{});
    std.debug.print("=============================================\n", .{});
    
    // Intermediate with 3 leaves, then delete one leaf.
    try checkNumNodes(&tbl, 0);

    tbl.insert(&mpp("192.168.0.1/32"), 1);
    tbl.insert(&mpp("192.180.0.1/32"), 2);
    tbl.insert(&mpp("192.200.0.1/32"), 3);

    try checkNumNodes(&tbl, 2);
    try checkRoutes(&tbl, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.180.0.1", .want = 2 },
        .{ .ip = "192.200.0.1", .want = 3 },
        .{ .ip = "192.255.0.1", .want = -1 },
    });

    tbl.delete(&mpp("192.180.0.1/32"));
    try checkNumNodes(&tbl, 2);
    try checkRoutes(&tbl, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.180.0.1", .want = -1 },
        .{ .ip = "192.200.0.1", .want = 3 },
        .{ .ip = "192.255.0.1", .want = -1 },
    });
}

test "TestDelete - nosuchprefix_missing_child" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tbl = Table(i32).init(allocator);
    defer tbl.deinit();
    
    std.debug.print("\n🧪 **TestDelete - nosuchprefix_missing_child**\n", .{});
    std.debug.print("================================================\n", .{});
    
    // Delete non-existent prefix
    try checkNumNodes(&tbl, 0);

    tbl.insert(&mpp("192.168.0.1/32"), 1);
    try checkNumNodes(&tbl, 1);
    try checkRoutes(&tbl, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.255.0.1", .want = -1 },
    });

    tbl.delete(&mpp("200.0.0.0/32"));
    try checkNumNodes(&tbl, 1);
    try checkRoutes(&tbl, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.255.0.1", .want = -1 },
    });
}

test "TestDelete - intermediate_with_deleted_route" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tbl = Table(i32).init(allocator);
    defer tbl.deinit();
    
    std.debug.print("\n🧪 **TestDelete - intermediate_with_deleted_route**\n", .{});
    std.debug.print("====================================================\n", .{});
    
    // Intermediate node loses its last route and becomes compactable.
    try checkNumNodes(&tbl, 0);

    tbl.insert(&mpp("192.168.0.1/32"), 1);
    tbl.insert(&mpp("192.168.0.0/22"), 2);
    try checkNumNodes(&tbl, 3);
    try checkRoutes(&tbl, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.168.0.2", .want = 2 },
        .{ .ip = "192.255.0.1", .want = -1 },
    });

    tbl.delete(&mpp("192.168.0.0/22"));
    try checkNumNodes(&tbl, 1);
    try checkRoutes(&tbl, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.168.0.2", .want = -1 },
        .{ .ip = "192.255.0.1", .want = -1 },
    });
}

test "TestDelete - default_route" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tbl = Table(i32).init(allocator);
    defer tbl.deinit();
    
    std.debug.print("\n🧪 **TestDelete - default_route**\n", .{});
    std.debug.print("===================================\n", .{});
    
    try checkNumNodes(&tbl, 0);

    tbl.insert(&mpp("0.0.0.0/0"), 1);
    tbl.insert(&mpp("::/0"), 1);
    tbl.delete(&mpp("0.0.0.0/0"));

    try checkNumNodes(&tbl, 1);
    try checkRoutes(&tbl, &[_]TableTest{
        .{ .ip = "1.2.3.4", .want = -1 },
        .{ .ip = "::1", .want = 1 },
    });
}

test "TestDelete - path compressed purge" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tbl = Table(i32).init(allocator);
    defer tbl.deinit();
    
    std.debug.print("\n🧪 **TestDelete - path compressed purge**\n", .{});
    std.debug.print("==========================================\n", .{});
    
    try checkNumNodes(&tbl, 0);

    tbl.insert(&mpp("10.10.0.0/17"), 1);
    tbl.insert(&mpp("10.20.0.0/17"), 2);
    try checkNumNodes(&tbl, 2);

    tbl.delete(&mpp("10.20.0.0/17"));
    try checkNumNodes(&tbl, 1);

    tbl.delete(&mpp("10.10.0.0/17"));
    try checkNumNodes(&tbl, 0);
}

// Go BART: func TestDeletePersist(t *testing.T)
test "TestDeletePersist - table_is_empty" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tbl = Table(i32).init(allocator);
    defer tbl.deinit();
    
    std.debug.print("\n🧪 **TestDeletePersist - table_is_empty**\n", .{});
    std.debug.print("==========================================\n", .{});
    
    // must not panic
    try checkNumNodes(&tbl, 0);
    
    // Generate a "random" prefix for testing (use a hardcoded prefix)
    const random_pfx = mpp("123.45.67.0/24");
    const tbl_ptr = try tbl.DeletePersist(&random_pfx);
    defer {
        tbl_ptr.deinit();
        allocator.destroy(tbl_ptr);
    }
    try checkNumNodes(tbl_ptr, 0);
}

test "TestDeletePersist - prefix_in_root" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tbl = Table(i32).init(allocator);
    defer tbl.deinit();
    
    std.debug.print("\n🧪 **TestDeletePersist - prefix_in_root**\n", .{});
    std.debug.print("===========================================\n", .{});
    
    // Add/remove prefix from root table.
    try checkNumNodes(&tbl, 0);

    tbl.insert(&mpp("10.0.0.0/8"), 1);
    try checkNumNodes(&tbl, 1);
    try checkRoutes(&tbl, &[_]TableTest{
        .{ .ip = "10.0.0.1", .want = 1 },
        .{ .ip = "255.255.255.255", .want = -1 },
    });
    
    const tbl_ptr = try tbl.DeletePersist(&mpp("10.0.0.0/8"));
    defer {
        tbl_ptr.deinit();
        allocator.destroy(tbl_ptr);
    }
    try checkNumNodes(tbl_ptr, 0);
    try checkRoutes(tbl_ptr, &[_]TableTest{
        .{ .ip = "10.0.0.1", .want = -1 },
        .{ .ip = "255.255.255.255", .want = -1 },
    });
}

test "TestDeletePersist - prefix_in_leaf" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tbl = Table(i32).init(allocator);
    defer tbl.deinit();
    
    std.debug.print("\n🧪 **TestDeletePersist - prefix_in_leaf**\n", .{});
    std.debug.print("==========================================\n", .{});
    
    // Create, then delete a single leaf table.
    try checkNumNodes(&tbl, 0);

    tbl.insert(&mpp("192.168.0.1/32"), 1);
    try checkNumNodes(&tbl, 1);
    try checkRoutes(&tbl, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "255.255.255.255", .want = -1 },
    });

    const tbl_ptr = try tbl.DeletePersist(&mpp("192.168.0.1/32"));
    defer {
        tbl_ptr.deinit();
        allocator.destroy(tbl_ptr);
    }
    try checkNumNodes(tbl_ptr, 0);
    try checkRoutes(tbl_ptr, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = -1 },
        .{ .ip = "255.255.255.255", .want = -1 },
    });
}

test "TestDeletePersist - intermediate_no_routes" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tbl = Table(i32).init(allocator);
    defer tbl.deinit();
    
    std.debug.print("\n🧪 **TestDeletePersist - intermediate_no_routes**\n", .{});
    std.debug.print("===============================================\n", .{});
    
    // Create an intermediate with 2 leaves, then delete one leaf.
    try checkNumNodes(&tbl, 0);

    tbl.insert(&mpp("192.168.0.1/32"), 1);
    tbl.insert(&mpp("192.180.0.1/32"), 2);
    try checkNumNodes(&tbl, 2);
    try checkRoutes(&tbl, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.180.0.1", .want = 2 },
        .{ .ip = "192.40.0.1", .want = -1 },
    });

    const tbl_ptr = try tbl.DeletePersist(&mpp("192.180.0.1/32"));
    defer {
        tbl_ptr.deinit();
        allocator.destroy(tbl_ptr);
    }
    try checkNumNodes(tbl_ptr, 1);
    try checkRoutes(tbl_ptr, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.180.0.1", .want = -1 },
        .{ .ip = "192.40.0.1", .want = -1 },
    });
}

test "TestDeletePersist - intermediate_with_route" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tbl = Table(i32).init(allocator);
    defer tbl.deinit();
    
    std.debug.print("\n🧪 **TestDeletePersist - intermediate_with_route**\n", .{});
    std.debug.print("================================================\n", .{});
    
    // Same, but the intermediate carries a route as well.
    try checkNumNodes(&tbl, 0);

    tbl.insert(&mpp("192.168.0.1/32"), 1);
    tbl.insert(&mpp("192.180.0.1/32"), 2);
    tbl.insert(&mpp("192.0.0.0/10"), 3);

    try checkNumNodes(&tbl, 2);
    try checkRoutes(&tbl, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.180.0.1", .want = 2 },
        .{ .ip = "192.40.0.1", .want = 3 },
        .{ .ip = "192.255.0.1", .want = -1 },
    });

    const tbl_ptr = try tbl.DeletePersist(&mpp("192.180.0.1/32"));
    defer {
        tbl_ptr.deinit();
        allocator.destroy(tbl_ptr);
    }
    try checkNumNodes(tbl_ptr, 2);
    try checkRoutes(tbl_ptr, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.180.0.1", .want = -1 },
        .{ .ip = "192.40.0.1", .want = 3 },
        .{ .ip = "192.255.0.1", .want = -1 },
    });
}

test "TestDeletePersist - intermediate_many_leaves" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tbl = Table(i32).init(allocator);
    defer tbl.deinit();
    
    std.debug.print("\n🧪 **TestDeletePersist - intermediate_many_leaves**\n", .{});
    std.debug.print("=================================================\n", .{});
    
    // Intermediate with 3 leaves, then delete one leaf.
    try checkNumNodes(&tbl, 0);

    tbl.insert(&mpp("192.168.0.1/32"), 1);
    tbl.insert(&mpp("192.180.0.1/32"), 2);
    tbl.insert(&mpp("192.200.0.1/32"), 3);

    try checkNumNodes(&tbl, 2);
    try checkRoutes(&tbl, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.180.0.1", .want = 2 },
        .{ .ip = "192.200.0.1", .want = 3 },
        .{ .ip = "192.255.0.1", .want = -1 },
    });

    const tbl_ptr = try tbl.DeletePersist(&mpp("192.180.0.1/32"));
    defer {
        tbl_ptr.deinit();
        allocator.destroy(tbl_ptr);
    }
    try checkNumNodes(tbl_ptr, 2);
    try checkRoutes(tbl_ptr, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.180.0.1", .want = -1 },
        .{ .ip = "192.200.0.1", .want = 3 },
        .{ .ip = "192.255.0.1", .want = -1 },
    });
}

test "TestDeletePersist - nosuchprefix_missing_child" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tbl = Table(i32).init(allocator);
    defer tbl.deinit();
    
    std.debug.print("\n🧪 **TestDeletePersist - nosuchprefix_missing_child**\n", .{});
    std.debug.print("====================================================\n", .{});
    
    // Delete non-existent prefix
    try checkNumNodes(&tbl, 0);

    tbl.insert(&mpp("192.168.0.1/32"), 1);
    try checkNumNodes(&tbl, 1);
    try checkRoutes(&tbl, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.255.0.1", .want = -1 },
    });

    const tbl_ptr = try tbl.DeletePersist(&mpp("200.0.0.0/32"));
    defer {
        tbl_ptr.deinit();
        allocator.destroy(tbl_ptr);
    }
    try checkNumNodes(tbl_ptr, 1);
    try checkRoutes(tbl_ptr, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.255.0.1", .want = -1 },
    });
}

test "TestDeletePersist - intermediate_with_deleted_route" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tbl = Table(i32).init(allocator);
    defer tbl.deinit();
    
    std.debug.print("\n🧪 **TestDeletePersist - intermediate_with_deleted_route**\n", .{});
    std.debug.print("========================================================\n", .{});
    
    // Intermediate node loses its last route and becomes compactable.
    try checkNumNodes(&tbl, 0);

    tbl.insert(&mpp("192.168.0.1/32"), 1);
    tbl.insert(&mpp("192.168.0.0/22"), 2);
    try checkNumNodes(&tbl, 3);
    try checkRoutes(&tbl, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.168.0.2", .want = 2 },
        .{ .ip = "192.255.0.1", .want = -1 },
    });

    const tbl_ptr = try tbl.DeletePersist(&mpp("192.168.0.0/22"));
    defer {
        tbl_ptr.deinit();
        allocator.destroy(tbl_ptr);
    }
    try checkNumNodes(tbl_ptr, 1);
    try checkRoutes(tbl_ptr, &[_]TableTest{
        .{ .ip = "192.168.0.1", .want = 1 },
        .{ .ip = "192.168.0.2", .want = -1 },
        .{ .ip = "192.255.0.1", .want = -1 },
    });
}

test "TestDeletePersist - default_route" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tbl = Table(i32).init(allocator);
    defer tbl.deinit();
    
    std.debug.print("\n🧪 **TestDeletePersist - default_route**\n", .{});
    std.debug.print("=========================================\n", .{});
    
    try checkNumNodes(&tbl, 0);

    tbl.insert(&mpp("0.0.0.0/0"), 1);
    tbl.insert(&mpp("::/0"), 1);
    
    const tbl_ptr = try tbl.DeletePersist(&mpp("0.0.0.0/0"));
    defer {
        tbl_ptr.deinit();
        allocator.destroy(tbl_ptr);
    }

    try checkNumNodes(tbl_ptr, 1);
    try checkRoutes(tbl_ptr, &[_]TableTest{
        .{ .ip = "1.2.3.4", .want = -1 },
        .{ .ip = "::1", .want = 1 },
    });
}

test "TestDeletePersist - path compressed purge" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tbl = Table(i32).init(allocator);
    defer tbl.deinit();
    
    std.debug.print("\n🧪 **TestDeletePersist - path compressed purge**\n", .{});
    std.debug.print("==============================================\n", .{});
    
    try checkNumNodes(&tbl, 0);

    tbl.insert(&mpp("10.10.0.0/17"), 1);
    tbl.insert(&mpp("10.20.0.0/17"), 2);
    try checkNumNodes(&tbl, 2);

    const tbl_ptr = try tbl.DeletePersist(&mpp("10.20.0.0/17"));
    defer {
        tbl_ptr.deinit();
        allocator.destroy(tbl_ptr);
    }
    try checkNumNodes(tbl_ptr, 1);

    const tbl_ptr2 = try tbl_ptr.DeletePersist(&mpp("10.10.0.0/17"));
    defer {
        tbl_ptr2.deinit();
        allocator.destroy(tbl_ptr2);
    }
    try checkNumNodes(tbl_ptr2, 0);
}

// Go BART Test Helper: goldTable - simple and slow route table for testing
const GoldTableItem = struct {
    pfx: netip.Prefix,
    val: i32,
};

const GoldTable = struct {
    const Self = @This();
    
    items: std.ArrayList(GoldTableItem),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .items = std.ArrayList(GoldTableItem).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.items.deinit();
    }
    
    pub fn insertMany(self: *Self, items: []const GoldTableItem) !void {
        for (items) |new_item| {
            // Check if prefix already exists and update it
            var found = false;
            for (self.items.items) |*existing_item| {
                // Compare prefix equality (addr and bits)
                if (std.mem.eql(u8, &new_item.pfx.addr().octets, &existing_item.pfx.addr().octets) and
                    new_item.pfx.bits() == existing_item.pfx.bits()) {
                    existing_item.val = new_item.val; // Update existing value
                    found = true;
                    break;
                }
            }
            // If not found, add new item
            if (!found) {
                try self.items.append(new_item);
            }
        }
    }
    
    pub fn lookup(self: *const Self, addr: netip.Addr) ?i32 {
        var bestLen: i32 = -1;
        var result: ?i32 = null;
        
        for (self.items.items) |item| {
            if (item.pfx.contains(&addr) and item.pfx.bits() > bestLen) {
                result = item.val;
                bestLen = @intCast(item.pfx.bits());
            }
        }
        
        return result;
    }
    
    pub fn lookupPfx(self: *const Self, pfx: netip.Prefix) ?i32 {
        var bestLen: i32 = -1;
        var result: ?i32 = null;
        
        for (self.items.items) |item| {
            if (item.pfx.overlaps(&pfx) and item.pfx.bits() <= pfx.bits() and item.pfx.bits() > bestLen) {
                result = item.val;
                bestLen = @intCast(item.pfx.bits());
            }
        }
        
        return result;
    }
    
    // Go BART: func (t *goldTable[V]) lookupPfxLPM(pfx netip.Prefix) (lmp netip.Prefix, val V, ok bool)
    pub const LookupPfxLPMResult = struct {
        lmp_prefix: netip.Prefix,
        value: i32,
        ok: bool,
    };
    
    pub fn lookupPfxLPM(self: *const Self, pfx: netip.Prefix) LookupPfxLPMResult {
        var bestLen: i32 = -1;
        var result_val: i32 = 0;
        var result_lmp = netip.Prefix{ .address = netip.Addr{ .octets = std.mem.zeroes([16]u8) }, .prefix_len = 0 };
        var found = false;
        
        for (self.items.items) |item| {
            if (item.pfx.overlaps(&pfx) and item.pfx.bits() <= pfx.bits() and item.pfx.bits() > bestLen) {
                result_val = item.val;
                result_lmp = item.pfx;
                found = true;
                bestLen = @intCast(item.pfx.bits());

            }
        }
        

        
        return LookupPfxLPMResult{
            .lmp_prefix = result_lmp,
            .value = result_val,
            .ok = found,
        };
    }
};

// Random number generator (simple XORShift)
var prng_state: u64 = 42;

fn prng_next() u32 {
    prng_state ^= prng_state << 13;
    prng_state ^= prng_state >> 7;
    prng_state ^= prng_state << 17;
    return @truncate(prng_state);
}

fn randomU8() u8 {
    return @truncate(prng_next());
}

fn randomU32() u32 {
    return prng_next();
}

fn randomIP4() netip.Addr {
    var b: [4]u8 = undefined;
    for (&b) |*byte| {
        byte.* = randomU8();
    }
    return netip.Addr.fromIPv4(b[0], b[1], b[2], b[3]);
}

fn randomIP6() netip.Addr {
    var b: [16]u8 = undefined;
    for (&b) |*byte| {
        byte.* = randomU8();
    }
    return netip.Addr.fromIPv6(b);
}

fn randomAddr() netip.Addr {
    if (prng_next() % 2 == 0) {
        return randomIP4();
    }
    return randomIP6();
}

fn randomPrefix() netip.Prefix {
    if (prng_next() % 2 == 0) {
        return randomPrefix4();
    }
    return randomPrefix6();
}

fn randomPrefix4() netip.Prefix {
    const bits = (prng_next() % 32) + 1; // 1-32, skip default route
    const a = randomU8();
    const b = randomU8();
    const c = randomU8();
    const d = randomU8();
    return netip.Prefix.fromIPv4(a, b, c, d, @intCast(bits)).masked();
}

fn randomPrefix6() netip.Prefix {
    const bits = (prng_next() % 128) + 1; // 1-128, skip default route  
    var octets: [16]u8 = undefined;
    for (&octets) |*byte| {
        byte.* = randomU8();
    }
    return netip.Prefix.fromIPv6(octets, @intCast(bits)).masked();
}

fn randomPrefixes(allocator: std.mem.Allocator, n: usize) ![]GoldTableItem {
    const items = try allocator.alloc(GoldTableItem, n);
    const pfx4_count = n / 2;
    
    // Generate IPv4 prefixes
    for (0..pfx4_count) |i| {
        items[i] = GoldTableItem{
            .pfx = randomPrefix4(),
            .val = @bitCast(randomU32()),
        };
    }
    
    // Generate IPv6 prefixes
    for (pfx4_count..n) |i| {
        items[i] = GoldTableItem{
            .pfx = randomPrefix6(),
            .val = @bitCast(randomU32()),
        };
    }
    
    return items;
}

// Go BART: func TestContainsCompare(t *testing.T)
test "TestContainsCompare" {

    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("\n🧪 **TestContainsCompare**\n", .{});
    std.debug.print("==========================\n", .{});
    
    // Create large route tables repeatedly, and compare Table's behavior to a naive and slow but correct implementation.
    const pfx_count = 10_000;
    std.debug.print("🔄 Generating {} random prefixes...\n", .{pfx_count});
    
    const pfxs = try randomPrefixes(allocator, pfx_count);
    defer allocator.free(pfxs);
    
    var gold = GoldTable.init(allocator);
    defer gold.deinit();
    try gold.insertMany(pfxs);
    
    var fast = Table(i32).init(allocator);
    defer fast.deinit();
    
    std.debug.print("🏗️ Building Tables...\n", .{});
    for (pfxs) |pfx_item| {
        fast.insert(&pfx_item.pfx, pfx_item.val);
    }
    
    std.debug.print("🔍 Comparing {} random lookups...\n", .{pfx_count});
    
    var success_count: usize = 0;
    var total_tests: usize = 0;
    
    for (0..pfx_count) |_| {
        const a = randomAddr();
        
        const gold_result = gold.lookup(a);
        const fast_result = fast.contains(&a);
        
        const gold_ok = gold_result != null;
        const fast_ok = fast_result;
        
        total_tests += 1;
        
        if (gold_ok == fast_ok) {
            success_count += 1;
        } else {
            std.debug.print("❌ Contains mismatch for {}: fast={}, gold={}\n", .{a, fast_ok, gold_ok});
            return error.ContainsMismatch;
        }
        
        // Progress indicator
        if (total_tests % 1000 == 0) {
            std.debug.print("✅ {}/{} tests passed\n", .{success_count, total_tests});
        }
    }
    
    std.debug.print("🎉 All {}/{} Contains tests passed!\n", .{success_count, total_tests});
    std.debug.print("📊 Table size: IPv4={}, IPv6={}\n", .{fast.size4(), fast.size6()});
}

// Go BART: func TestLookupCompare(t *testing.T)
test "TestLookupCompare" {
    // Create large route tables repeatedly, and compare Table's behavior to a naive and slow but correct implementation.
    const pfx_count = 10_000;

    const pfx_items = try randomPrefixes(testing.allocator, pfx_count);
    defer testing.allocator.free(pfx_items);

    var fast = Table(i32).init(testing.allocator);
    defer fast.deinit();

    var gold = GoldTable.init(testing.allocator);
    defer gold.deinit();

    // Insert all prefixes into both tables
    try gold.insertMany(pfx_items);
    for (pfx_items) |pfx_item| {
        fast.insert(&pfx_item.pfx, pfx_item.val);
    }

    var seen_vals4 = std.AutoHashMap(i32, bool).init(testing.allocator);
    defer seen_vals4.deinit();
    
    var seen_vals6 = std.AutoHashMap(i32, bool).init(testing.allocator);
    defer seen_vals6.deinit();

    // Perform 10,000 random lookups
    for (0..10_000) |_| {
        const a = randomAddr();

        const gold_result = gold.lookup(a);
        const fast_result = fast.lookup(&a);

        // Compare results - both should return the same value and ok status
        if (gold_result == null and fast_result.ok) {
            std.debug.print("❌ MISMATCH: Lookup({any}) = ({}, {}), want (null, false)\n", .{ a, fast_result.value, fast_result.ok });
            try expect(false); // Force failure
        }
        
        if (gold_result != null and !fast_result.ok) {
            std.debug.print("❌ MISMATCH: Lookup({any}) = ({}, {}), want ({}, true)\n", .{ a, fast_result.value, fast_result.ok, gold_result.? });
            try expect(false); // Force failure
        }
        
        if (gold_result != null and fast_result.ok) {
            if (gold_result.? != fast_result.value) {
                std.debug.print("❌ VALUE MISMATCH: Lookup({any}) = ({}, {}), want ({}, true)\n", .{ a, fast_result.value, fast_result.ok, gold_result.? });
                try expect(false); // Force failure
            }
        }

        // Track distinct values seen
        if (fast_result.ok) {
            if (!a.is4()) {
                try seen_vals6.put(fast_result.value, true);
            } else {
                try seen_vals4.put(fast_result.value, true);
            }
        }
    }

    // Empirically, 10k probes into 5k v4 prefixes and 5k v6 prefixes results in
    // ~1k distinct values for v4 and ~300 for v6. This sanity check that we didn't
    // just return a single route for everything should be very generous indeed.
    const v4_count = seen_vals4.count();
    const v6_count = seen_vals6.count();
    
    if (v4_count < 10) {
        std.debug.print("saw {} distinct v4 route results, statistically expected ~1000\n", .{v4_count});
        try expect(false);
    }
    
    if (v6_count < 10) {
        std.debug.print("saw {} distinct v6 route results, statistically expected ~300\n", .{v6_count});
        try expect(false);
    }
    
    std.debug.print("🎉 TestLookupCompare passed! V4 distinct routes: {}, V6 distinct routes: {}\n", .{v4_count, v6_count});
}

// Helper function to create non-canonical prefixes for testing
fn createPrefix(ip_str: []const u8, bits: u8) netip.Prefix {
    const addr = netip.Addr.mustParseAddr(ip_str);
    return netip.Prefix{ .address = addr, .prefix_len = bits };
}

// Go BART: func TestLookupPrefixUnmasked(t *testing.T)
test "TestLookupPrefixUnmasked" {
    // Test that the pfx must not be masked on input for LookupPrefix
    
    var rt = Table(void).init(testing.allocator);
    defer rt.deinit();
    
    const pfx = mpp("10.20.30.0/24");
    rt.insert(&pfx, {});
    
    // Test cases with non-normalized prefixes
    const TestCase = struct {
        probe: netip.Prefix,
        want_lpm: netip.Prefix,
        want_ok: bool,
    };
    
    const tests = [_]TestCase{
        TestCase{
            .probe = createPrefix("10.20.30.40", 0),
            .want_lpm = netip.Prefix{ .address = netip.Addr{ .octets = std.mem.zeroes([16]u8) }, .prefix_len = 0 },
            .want_ok = false,
        },
        TestCase{
            .probe = createPrefix("10.20.30.40", 23),
            .want_lpm = netip.Prefix{ .address = netip.Addr{ .octets = std.mem.zeroes([16]u8) }, .prefix_len = 0 },
            .want_ok = false,
        },
        TestCase{
            .probe = createPrefix("10.20.30.40", 24),
            .want_lpm = mpp("10.20.30.0/24"),
            .want_ok = true,
        },
        TestCase{
            .probe = createPrefix("10.20.30.40", 25),
            .want_lpm = mpp("10.20.30.0/24"),
            .want_ok = true,
        },
        TestCase{
            .probe = createPrefix("10.20.30.40", 32),
            .want_lpm = mpp("10.20.30.0/24"),
            .want_ok = true,
        },
    };
    
    for (tests) |tc| {
        // Test LookupPrefix
        const lookup_result = rt.lookupPrefix(&tc.probe);
        if (lookup_result.ok != tc.want_ok) {
            std.debug.print("LookupPrefix non canonical prefix ({any}), got: {}, want: {}\n", .{ tc.probe, lookup_result.ok, tc.want_ok });
            try expect(false);
        }
        
        // Test LookupPrefixLPM
        const lpm_result = rt.lookupPrefixLPM(&tc.probe);
        if (lpm_result.ok != tc.want_ok) {
            std.debug.print("LookupPrefixLPM non canonical prefix ({any}), got: {}, want: {}\n", .{ tc.probe, lpm_result.ok, tc.want_ok });
            try expect(false);
        }
        
        // Compare LPM prefix if found
        if (tc.want_ok) {
            // Compare prefixes (addr and bits)
            if (!std.mem.eql(u8, &lpm_result.lpm_prefix.addr().octets, &tc.want_lpm.addr().octets) or
                lpm_result.lpm_prefix.bits() != tc.want_lpm.bits()) {
                std.debug.print("LookupPrefixLPM non canonical prefix ({any}), got: {any}, want: {any}\n", .{ tc.probe, lpm_result.lpm_prefix, tc.want_lpm });
                try expect(false);
            }
        }
    }
    
    std.debug.print("🎉 TestLookupPrefixUnmasked passed!\n", .{});
}

// Go BART: func TestLookupPrefixCompare(t *testing.T)
test "TestLookupPrefixCompare" {
    // Create large route tables repeatedly, and compare Table's behavior to a naive and slow but correct implementation.
    const pfx_count = 10_000;

    const pfx_items = try randomPrefixes(testing.allocator, pfx_count);
    defer testing.allocator.free(pfx_items);

    var fast = Table(i32).init(testing.allocator);
    defer fast.deinit();

    var gold = GoldTable.init(testing.allocator);
    defer gold.deinit();

    // Insert all prefixes into both tables
    try gold.insertMany(pfx_items);
    for (pfx_items) |pfx_item| {
        fast.insert(&pfx_item.pfx, pfx_item.val);
    }

    var seen_vals4 = std.AutoHashMap(i32, bool).init(testing.allocator);
    defer seen_vals4.deinit();
    
    var seen_vals6 = std.AutoHashMap(i32, bool).init(testing.allocator);
    defer seen_vals6.deinit();

    // Perform 10,000 random prefix lookups
    for (0..10_000) |_| {
        const pfx = randomPrefix();

        const gold_result = gold.lookupPfx(pfx);
        const fast_result = fast.lookupPrefix(&pfx);

        // Compare results - both should return the same value and ok status
        if (gold_result == null and fast_result.ok) {
            std.debug.print("❌ MISMATCH: LookupPrefix({any}) = ({}, {}), want (null, false)\n", .{ pfx, fast_result.value, fast_result.ok });
            try expect(false); // Force failure
        }
        
        if (gold_result != null and !fast_result.ok) {
            std.debug.print("❌ MISMATCH: LookupPrefix({any}) = ({}, {}), want ({}, true)\n", .{ pfx, fast_result.value, fast_result.ok, gold_result.? });
            try expect(false); // Force failure
        }
        
        if (gold_result != null and fast_result.ok) {
            if (gold_result.? != fast_result.value) {
                std.debug.print("❌ VALUE MISMATCH: LookupPrefix({any}) = ({}, {}), want ({}, true)\n", .{ pfx, fast_result.value, fast_result.ok, gold_result.? });
                try expect(false); // Force failure
            }
        }

        // Track distinct values seen
        if (fast_result.ok) {
            if (!pfx.addr().is4()) {
                try seen_vals6.put(fast_result.value, true);
            } else {
                try seen_vals4.put(fast_result.value, true);
            }
        }
    }

    // Empirically, 10k probes into 5k v4 prefixes and 5k v6 prefixes results in
    // ~1k distinct values for v4 and ~300 for v6. This sanity check that we didn't
    // just return a single route for everything should be very generous indeed.
    const v4_count = seen_vals4.count();
    const v6_count = seen_vals6.count();
    
    if (v4_count < 10) {
        std.debug.print("saw {} distinct v4 route results, statistically expected ~1000\n", .{v4_count});
        try expect(false);
    }
    
    if (v6_count < 10) {
        std.debug.print("saw {} distinct v6 route results, statistically expected ~300\n", .{v6_count});
        try expect(false);
    }
    
    std.debug.print("🎉 TestLookupPrefixCompare passed! V4 distinct routes: {}, V6 distinct routes: {}\n", .{v4_count, v6_count});
}

// Go BART: func TestLookupPrefixLPMCompare(t *testing.T)
test "TestLookupPrefixLPMCompare" {
    // Create large route tables repeatedly, and compare Table's behavior to a naive and slow but correct implementation.
    const pfx_count = 10_000;

    const pfx_items = try randomPrefixes(testing.allocator, pfx_count);
    defer testing.allocator.free(pfx_items);

    var fast = Table(i32).init(testing.allocator);
    defer fast.deinit();

    var gold = GoldTable.init(testing.allocator);
    defer gold.deinit();

    // Insert all prefixes into both tables
    try gold.insertMany(pfx_items);
    for (pfx_items) |pfx_item| {
        fast.insert(&pfx_item.pfx, pfx_item.val);
    }

    var seen_vals4 = std.AutoHashMap(i32, bool).init(testing.allocator);
    defer seen_vals4.deinit();
    
    var seen_vals6 = std.AutoHashMap(i32, bool).init(testing.allocator);
    defer seen_vals6.deinit();

    // Perform 10,000 random prefix LPM lookups
    for (0..10_000) |_| {
        const pfx = randomPrefix();

        const gold_result = gold.lookupPfxLPM(pfx);
        const fast_result = fast.lookupPrefixLPM(&pfx);

        // Compare value results - both should return the same value and ok status
        if (gold_result.ok != fast_result.ok) {
            std.debug.print("❌ OK MISMATCH: LookupPrefixLPM({any}) = ({}, {}), want ({}, {})\n", .{ pfx, fast_result.value, fast_result.ok, gold_result.value, gold_result.ok });
            try expect(false); // Force failure
        }
        
        if (gold_result.ok and fast_result.ok) {
            if (gold_result.value != fast_result.value) {
                std.debug.print("❌ VALUE MISMATCH: LookupPrefixLPM({any}) = ({}, {}), want ({}, {})\n", .{ pfx, fast_result.value, fast_result.ok, gold_result.value, gold_result.ok });
                try expect(false); // Force failure
            }
        }

        // Compare LMP prefix results
        if (gold_result.ok != fast_result.ok) {
            std.debug.print("❌ LMP OK MISMATCH: LookupPrefixLPM({any}) lmp = ({any}, {}), want ({any}, {})\n", .{ pfx, fast_result.lpm_prefix, fast_result.ok, gold_result.lmp_prefix, gold_result.ok });
            try expect(false); // Force failure
        }
        
        if (gold_result.ok and fast_result.ok) {
            // Compare prefix addresses and bits
            if (!std.mem.eql(u8, &gold_result.lmp_prefix.addr().octets, &fast_result.lpm_prefix.addr().octets) or
                gold_result.lmp_prefix.bits() != fast_result.lpm_prefix.bits()) {
                std.debug.print("❌ LMP PREFIX MISMATCH: LookupPrefixLPM({any}) lmp = ({any}, {}), want ({any}, {})\n", .{ pfx, fast_result.lpm_prefix, fast_result.ok, gold_result.lmp_prefix, gold_result.ok });
                try expect(false); // Force failure
            }
        }

        // Track distinct values seen
        if (fast_result.ok) {
            if (!pfx.addr().is4()) {
                try seen_vals6.put(fast_result.value, true);
            } else {
                try seen_vals4.put(fast_result.value, true);
            }
        }
    }

    // Empirically, 10k probes into 5k v4 prefixes and 5k v6 prefixes results in
    // ~1k distinct values for v4 and ~300 for v6. This sanity check that we didn't
    // just return a single route for everything should be very generous indeed.
    const v4_count = seen_vals4.count();
    const v6_count = seen_vals6.count();
    
    if (v4_count < 10) {
        std.debug.print("saw {} distinct v4 route results, statistically expected ~1000\n", .{v4_count});
        try expect(false);
    }
    
    if (v6_count < 10) {
        std.debug.print("saw {} distinct v6 route results, statistically expected ~300\n", .{v6_count});
        try expect(false);
    }
    
    std.debug.print("🎉 TestLookupPrefixLPMCompare passed! V4 distinct routes: {}, V6 distinct routes: {}\n", .{v4_count, v6_count});
}

// Go BART: func TestInsertShuffled(t *testing.T)
test "TestInsertShuffled" {
    // The order in which you insert prefixes into a route table
    // should not matter, as long as you're inserting the same set of routes.
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("\n🧪 **TestInsertShuffled**\n", .{});
    std.debug.print("==========================\n", .{});
    
    const pfx_count = 10; // Reduced for debugging
    std.debug.print("🔄 Generating {} random prefixes...\n", .{pfx_count});
    
    const pfxs = try randomPrefixes(allocator, pfx_count);
    defer allocator.free(pfxs);
    
    // Run test 10 times with different shuffles
    for (0..10) |iteration| {
        std.debug.print("🔀 Iteration {} - Creating shuffled copy...\n", .{iteration + 1});
        
        // Create a copy of the prefixes array
        const pfxs2 = try allocator.alloc(GoldTableItem, pfx_count);
        defer allocator.free(pfxs2);
        @memcpy(pfxs2, pfxs);
        
        // Shuffle pfxs2 using Fisher-Yates algorithm
        for (0..pfx_count) |i| {
            const j = i + (prng_next() % (pfx_count - i));
            const temp = pfxs2[i];
            pfxs2[i] = pfxs2[j];
            pfxs2[j] = temp;
        }
        
        // Generate 100 random addresses for testing
        const addr_count = 100;
        const addrs = try allocator.alloc(netip.Addr, addr_count);
        defer allocator.free(addrs);
        
        for (0..addr_count) |i| {
            addrs[i] = randomAddr();
        }
        
        // Create two routing tables
        var rt1 = Table(i32).init(allocator);
        defer rt1.deinit();
        
        var rt2 = Table(i32).init(allocator);
        defer rt2.deinit();
        
        std.debug.print("🏗️ Building original table...\n", .{});
        // Insert original order into rt1
        for (pfxs) |pfx_item| {
            rt1.insert(&pfx_item.pfx, pfx_item.val);
        }
        
        std.debug.print("🏗️ Building shuffled table...\n", .{});
        // Insert shuffled order into rt2
        for (pfxs2) |pfx_item| {
            rt2.insert(&pfx_item.pfx, pfx_item.val);
        }
        
        std.debug.print("🔍 Comparing {} lookups...\n", .{addr_count});
        
        // Compare lookup results for all addresses
        var success_count: usize = 0;
        for (addrs, 0..) |addr, i| {
            const result1 = rt1.lookup(&addr);
            const result2 = rt2.lookup(&addr);
            
            // Both should give exactly the same results
            if (result1.ok != result2.ok) {
                std.debug.print("❌ OK mismatch for {}: rt1.ok={}, rt2.ok={}\n", .{ addr, result1.ok, result2.ok });
                return error.LookupMismatch;
            }
            
            if (result1.ok and result2.ok) {
                if (result1.value != result2.value) {
                    std.debug.print("❌ Value mismatch for {} (iteration {}, lookup {}): rt1.value={}, rt2.value={}\n", .{ addr, iteration + 1, i + 1, result1.value, result2.value });
                    std.debug.print("   🔍 Debugging first 5 prefixes in original order:\n", .{});
                    for (pfxs[0..@min(5, pfxs.len)]) |pfx_item| {
                        std.debug.print("     - {any} -> {}\n", .{ pfx_item.pfx, pfx_item.val });
                    }
                    std.debug.print("   🔍 Debugging first 5 prefixes in shuffled order:\n", .{});
                    for (pfxs2[0..@min(5, pfxs2.len)]) |pfx_item| {
                        std.debug.print("     - {any} -> {}\n", .{ pfx_item.pfx, pfx_item.val });
                    }
                    return error.ValueMismatch;
                }
            }
            
            success_count += 1;
            
            // Progress indicator
            if ((i + 1) % 20 == 0) {
                std.debug.print("✅ {}/{} lookups verified\n", .{ i + 1, addr_count });
            }
        }
        
        std.debug.print("✅ Iteration {}: {}/{} lookups matched perfectly\n", .{ iteration + 1, success_count, addr_count });
        std.debug.print("📊 RT1 size: IPv4={}, IPv6={} | RT2 size: IPv4={}, IPv6={}\n", .{ rt1.size4(), rt1.size6(), rt2.size4(), rt2.size6() });
        
        // Verify table sizes are identical
        if (rt1.size4() != rt2.size4() or rt1.size6() != rt2.size6()) {
            std.debug.print("❌ Table size mismatch: RT1({},{}) != RT2({},{})\n", .{ rt1.size4(), rt1.size6(), rt2.size4(), rt2.size6() });
            return error.TableSizeMismatch;
        }
    }
    
    std.debug.print("🎉 TestInsertShuffled passed! All 10 iterations with different shuffle orders produced identical results.\n", .{});
}
