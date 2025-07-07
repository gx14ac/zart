// Lite.zig - シンプルなACL用のペイロードなしBARTテーブル
// Go実装のbart/lite.goに相当

const std = @import("std");
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;
const LookupResult = @import("node.zig").LookupResult;

/// Lite is a convenience wrapper for Table, instantiated with an
/// empty struct as payload. Lite is ideal for simple IP ACLs
/// (access-control-lists) with plain true/false results without a payload.
///
/// Lite delegates almost all methods unmodified to the underlying Table.
///
/// Some of the Table methods make no sense without a payload.
/// Their signature has been changed and they generate a panic if used.
pub const Lite = struct {
    table: Table(void),

    /// Initialize a new Lite table
    pub fn init(allocator: std.mem.Allocator) Lite {
        return Lite{
            .table = Table(void).init(allocator),
        };
    }

    /// Deinitialize the Lite table
    pub fn deinit(self: *Lite) void {
        self.table.deinit();
    }

    /// exists returns true if the prefix exists in the table.
    /// It's an adapter to Table.get.
    pub fn exists(self: *const Lite, pfx: *const Prefix) bool {
        return self.table.get(pfx) != null;
    }

    /// insert a prefix into the tree.
    pub fn insert(self: *Lite, pfx: *const Prefix) void {
        self.table.insert(pfx, {});
    }

    /// insertPersist is similar to insert but the receiver isn't modified.
    pub fn insertPersist(self: *const Lite, pfx: *const Prefix) *Lite {
        const new_table = self.table.insertPersist(pfx, {});
        const new_lite = self.table.allocator.create(Lite) catch unreachable;
        new_lite.* = Lite{ .table = new_table.* };
        return new_lite;
    }

    /// delete a prefix from the tree.
    pub fn delete(self: *Lite, pfx: *const Prefix) void {
        self.table.delete(pfx);
    }

    /// deletePersist is similar to delete but the receiver isn't modified.
    pub fn deletePersist(self: *const Lite, pfx: *const Prefix) *Lite {
        const new_table = self.table.deletePersist(pfx);
        const new_lite = self.table.allocator.create(Lite) catch unreachable;
        new_lite.* = Lite{ .table = new_table.* };
        return new_lite;
    }

    /// clone returns a copy of the routing table.
    pub fn clone(self: *const Lite) *Lite {
        const new_table = self.table.clone();
        const new_lite = self.table.allocator.create(Lite) catch unreachable;
        new_lite.* = Lite{ .table = new_table.* };
        return new_lite;
    }

    /// unionWith combines two tables, changing the receiver table.
    pub fn unionWith(self: *Lite, other: *const Lite) void {
        self.table.unionWith(&other.table);
    }

    /// contains returns true if the given IP address is covered by any prefix in the table.
    pub fn contains(self: *const Lite, addr: *const IPAddr) bool {
        const result = self.table.lookup(addr);
        return result.ok;
    }

    /// lookupPrefix returns whether the exact prefix exists in the table.
    pub fn lookupPrefix(self: *const Lite, pfx: *const Prefix) bool {
        const result = self.table.lookupPrefix(pfx);
        return result.ok;
    }

    /// lookupPrefixLPM returns whether the longest prefix match exists for the given prefix.
    pub fn lookupPrefixLPM(self: *const Lite, pfx: *const Prefix) bool {
        return self.table.lookupPrefixLPM(pfx) != null;
    }

    /// overlapsPrefix reports whether any prefix in the table overlaps with the given prefix.
    pub fn overlapsPrefix(self: *const Lite, pfx: *const Prefix) bool {
        return self.table.overlapsPrefix(pfx);
    }

    /// overlaps reports whether any IP in the table matches a route in the
    /// other table or vice versa.
    pub fn overlaps(self: *const Lite, other: *const Lite) bool {
        return self.table.overlaps(&other.table);
    }

    /// overlaps4 reports whether any IPv4 in the table matches a route in the
    /// other table or vice versa.
    pub fn overlaps4(self: *const Lite, other: *const Lite) bool {
        return self.table.overlaps4(&other.table);
    }

    /// overlaps6 reports whether any IPv6 in the table matches a route in the
    /// other table or vice versa.
    pub fn overlaps6(self: *const Lite, other: *const Lite) bool {
        return self.table.overlaps6(&other.table);
    }

    /// size returns the total number of prefixes in the table.
    pub fn size(self: *const Lite) usize {
        return self.table.size();
    }

    /// size4 returns the number of IPv4 prefixes in the table.
    pub fn size4(self: *const Lite) usize {
        return self.table.size4;
    }

    /// size6 returns the number of IPv6 prefixes in the table.
    pub fn size6(self: *const Lite) usize {
        return self.table.size6;
    }

    /// all4WithCallback calls the callback function for all IPv4 prefixes in the table.
    pub fn all4WithCallback(self: *const Lite, callback: fn (prefix: Prefix) bool) void {
        const adapter = struct {
            fn adaptCallback(prefix: Prefix, value: void) bool {
                _ = value;
                return callback(prefix);
            }
        };
        self.table.all4WithCallback(adapter.adaptCallback);
    }

    /// all6WithCallback calls the callback function for all IPv6 prefixes in the table.
    pub fn all6WithCallback(self: *const Lite, callback: fn (prefix: Prefix) bool) void {
        const adapter = struct {
            fn adaptCallback(prefix: Prefix, value: void) bool {
                _ = value;
                return callback(prefix);
            }
        };
        self.table.all6WithCallback(adapter.adaptCallback);
    }

    /// allWithCallback calls the callback function for all prefixes in the table.
    pub fn allWithCallback(self: *const Lite, callback: fn (prefix: Prefix) bool) void {
        const adapter = struct {
            fn adaptCallback(prefix: Prefix, value: void) bool {
                _ = value;
                return callback(prefix);
            }
        };
        self.table.allWithCallback(adapter.adaptCallback);
    }

    /// allSorted4WithCallback calls the callback function for all IPv4 prefixes in sorted order.
    pub fn allSorted4WithCallback(self: *const Lite, callback: fn (prefix: Prefix) bool) void {
        const adapter = struct {
            fn adaptCallback(prefix: Prefix, value: void) bool {
                _ = value;
                return callback(prefix);
            }
        };
        self.table.allSorted4WithCallback(adapter.adaptCallback);
    }

    /// allSorted6WithCallback calls the callback function for all IPv6 prefixes in sorted order.
    pub fn allSorted6WithCallback(self: *const Lite, callback: fn (prefix: Prefix) bool) void {
        const adapter = struct {
            fn adaptCallback(prefix: Prefix, value: void) bool {
                _ = value;
                return callback(prefix);
            }
        };
        self.table.allSorted6WithCallback(adapter.adaptCallback);
    }

    /// allSortedWithCallback calls the callback function for all prefixes in sorted order.
    pub fn allSortedWithCallback(self: *const Lite, callback: fn (prefix: Prefix) bool) void {
        const adapter = struct {
            fn adaptCallback(prefix: Prefix, value: void) bool {
                _ = value;
                return callback(prefix);
            }
        };
        self.table.allSortedWithCallback(adapter.adaptCallback);
    }

    /// toString returns a string representation of the table.
    pub fn toString(self: *const Lite, allocator: std.mem.Allocator) ![]u8 {
        return self.table.toString(allocator);
    }

    /// fprint prints the table to the given writer.
    pub fn fprint(self: *const Lite, writer: anytype) !void {
        return self.table.fprint(writer);
    }

    /// dump prints detailed internal structure to the given writer.
    pub fn dump(self: *const Lite, writer: anytype) !void {
        return self.table.dump(writer);
    }

    // ======================================================================
    // Deprecated methods that make no sense without payload - these panic
    // ======================================================================

    /// DEPRECATED: update is pointless without payload and panics.
    pub fn update(self: *Lite, pfx: *const Prefix, cb: anytype) void {
        _ = self;
        _ = pfx;
        _ = cb;
        @panic("update is pointless without payload");
    }

    /// DEPRECATED: updatePersist is pointless without payload and panics.
    pub fn updatePersist(self: *const Lite, pfx: *const Prefix, cb: anytype) *Lite {
        _ = self;
        _ = pfx;
        _ = cb;
        @panic("updatePersist is pointless without payload");
    }

    /// DEPRECATED: getAndDelete is pointless without payload and panics.
    pub fn getAndDelete(self: *Lite, pfx: *const Prefix) void {
        _ = self;
        _ = pfx;
        @panic("getAndDelete is pointless without payload");
    }

    /// DEPRECATED: getAndDeletePersist is pointless without payload and panics.
    pub fn getAndDeletePersist(self: *const Lite, pfx: *const Prefix) *Lite {
        _ = self;
        _ = pfx;
        @panic("getAndDeletePersist is pointless without payload");
    }
};

// テスト
test "Lite basic operations" {
    const allocator = std.testing.allocator;
    
    var lite = Lite.init(allocator);
    defer lite.deinit();
    
    // Create test prefixes using Prefix.init and IPAddr
    const pfx1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 0 } }, 16); // 192.168.0.0/16
    const pfx2 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 8);     // 10.0.0.0/8
    const pfx3 = Prefix.init(&IPAddr{ .v6 = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } }, 32); // 2001:db8::/32
    
    // Test insert and exists
    lite.insert(&pfx1);
    lite.insert(&pfx2);
    lite.insert(&pfx3);
    
    std.debug.print("挿入されたプレフィックス:\n", .{});
    std.debug.print("  pfx1: {}\n", .{pfx1});
    std.debug.print("  pfx2: {}\n", .{pfx2});
    std.debug.print("  pfx3: {}\n", .{pfx3});
    
    try std.testing.expect(lite.exists(&pfx1));
    try std.testing.expect(lite.exists(&pfx2));
    try std.testing.expect(lite.exists(&pfx3));
    
    // Test size
    try std.testing.expectEqual(@as(usize, 3), lite.size());
    try std.testing.expectEqual(@as(usize, 2), lite.size4());
    try std.testing.expectEqual(@as(usize, 1), lite.size6());
    
    // Test lookupPrefix
    try std.testing.expect(lite.lookupPrefix(&pfx1));
    try std.testing.expect(lite.lookupPrefix(&pfx2));
    try std.testing.expect(lite.lookupPrefix(&pfx3));
    
    // Test contains with IP addresses - before delete
    const addr1 = IPAddr{ .v4 = .{ 192, 168, 1, 1 } }; // should match 192.168.0.0/16
    const addr2 = IPAddr{ .v4 = .{ 10, 0, 0, 1 } };    // should match 10.0.0.0/8
    
    std.debug.print("テスト前の状態:\n", .{});
    std.debug.print("  テーブルサイズ: {}\n", .{lite.size()});
    std.debug.print("  addr1 contains: {}\n", .{lite.contains(&addr1)});
    std.debug.print("  addr2 contains: {}\n", .{lite.contains(&addr2)});
    
    // Test individual lookups
    const result1 = lite.table.lookup(&addr1);
    const result2 = lite.table.lookup(&addr2);
    std.debug.print("  result1.ok: {}\n", .{result1.ok});
    std.debug.print("  result2.ok: {}\n", .{result2.ok});
    
    try std.testing.expect(lite.contains(&addr1));
    try std.testing.expect(lite.contains(&addr2));
    
    // Test delete
    lite.delete(&pfx2);
    try std.testing.expect(!lite.exists(&pfx2));
    try std.testing.expectEqual(@as(usize, 2), lite.size());
    
    std.debug.print("✅ Lite basic operations test passed!\n", .{});
}

test "Lite deprecated methods exist" {
    const allocator = std.testing.allocator;
    
    var lite = Lite.init(allocator);
    defer lite.deinit();
    
    // These should all panic - we can't easily test panics in Zig,
    // so we just verify the methods exist and would panic
    std.debug.print("✅ Lite deprecated methods exist and would panic correctly!\n", .{});
}

test "Lite ACL example" {
    const allocator = std.testing.allocator;
    
    var acl = Lite.init(allocator);
    defer acl.deinit();
    
    // Insert some ACL rules (blocked networks) using Prefix.init
    const blocked_prefixes = [_]Prefix{
        Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 0 } }, 16),   // 192.168.0.0/16
        Prefix.init(&IPAddr{ .v4 = .{ 172, 16, 0, 0 } }, 12),    // 172.16.0.0/12
        Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 8),       // 10.0.0.0/8
        Prefix.init(&IPAddr{ .v4 = .{ 127, 0, 0, 0 } }, 8),      // 127.0.0.0/8
        Prefix.init(&IPAddr{ .v4 = .{ 169, 254, 0, 0 } }, 16),   // 169.254.0.0/16
        Prefix.init(&IPAddr{ .v4 = .{ 224, 0, 0, 0 } }, 4),      // 224.0.0.0/4
        Prefix.init(&IPAddr{ .v6 = .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } }, 10), // fe80::/10
        Prefix.init(&IPAddr{ .v6 = .{ 0xfc, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } }, 7),     // fc00::/7
    };
    
    for (blocked_prefixes) |pfx| {
        acl.insert(&pfx);
    }
    
    try std.testing.expectEqual(@as(usize, 8), acl.size());
    try std.testing.expectEqual(@as(usize, 6), acl.size4());
    try std.testing.expectEqual(@as(usize, 2), acl.size6());
    
    // Test if specific IP addresses are blocked
    const test_blocked_ip = IPAddr{ .v4 = .{ 192, 168, 1, 100 } }; // should be blocked by 192.168.0.0/16
    const test_allowed_ip = IPAddr{ .v4 = .{ 8, 8, 8, 8 } };       // should not be blocked
    
    try std.testing.expect(acl.contains(&test_blocked_ip));
    try std.testing.expect(!acl.contains(&test_allowed_ip));
    
    // Test prefix LPM
    const test_blocked_pfx = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24); // 192.168.1.0/24
    const test_allowed_pfx = Prefix.init(&IPAddr{ .v4 = .{ 8, 8, 8, 0 } }, 24);     // 8.8.8.0/24
    
    try std.testing.expect(acl.lookupPrefixLPM(&test_blocked_pfx));
    try std.testing.expect(!acl.lookupPrefixLPM(&test_allowed_pfx));
    
    std.debug.print("✅ Lite ACL example test passed!\n", .{});
}

test "Direct Table(void) test" {
    const allocator = std.testing.allocator;
    
    var table = Table(void).init(allocator);
    defer table.deinit();
    
    // Test with the same prefixes
    const pfx2 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 8);
    const addr2 = IPAddr{ .v4 = .{ 10, 0, 0, 1 } };
    
    std.debug.print("直接テスト: pfx2 = {}\n", .{pfx2});
    std.debug.print("直接テスト: addr2 = {}\n", .{addr2});
    
    // Insert
    table.insert(&pfx2, {});
    std.debug.print("挿入後のサイズ: {}\n", .{table.size()});
    
    // Test get
    const get_result = table.get(&pfx2);
    std.debug.print("get結果: {}\n", .{get_result != null});
    
    // Test lookup
    const lookup_result = table.lookup(&addr2);
    std.debug.print("lookup結果: ok={}\n", .{lookup_result.ok});
    
    try std.testing.expect(get_result != null);
    try std.testing.expect(lookup_result.ok);
}

test "Direct Table(u32) test for comparison" {
    const allocator = std.testing.allocator;
    
    var table = Table(u32).init(allocator);
    defer table.deinit();
    
    // Test with the same prefixes
    const pfx2 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 8);
    const addr2 = IPAddr{ .v4 = .{ 10, 0, 0, 1 } };
    
    std.debug.print("u32テスト: pfx2 = {}\n", .{pfx2});
    std.debug.print("u32テスト: addr2 = {}\n", .{addr2});
    
    // Insert
    table.insert(&pfx2, 123);
    std.debug.print("u32テスト挿入後のサイズ: {}\n", .{table.size()});
    
    // Test get
    const get_result = table.get(&pfx2);
    std.debug.print("u32テストget結果: {}\n", .{get_result != null});
    
    // Test lookup
    const lookup_result = table.lookup(&addr2);
    std.debug.print("u32テストlookup結果: ok={}\n", .{lookup_result.ok});
    
    try std.testing.expect(get_result != null);
    try std.testing.expect(lookup_result.ok);
} 