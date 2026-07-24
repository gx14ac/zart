// Copyright (c) 2024 ZART Project
// SPDX-License-Identifier: MIT
//
// High-level AllowedIPs API for WireGuard peer routing.
// Wraps the BART Table to provide peer-indexed prefix management.

const std = @import("std");
const netip = @import("netip.zig");
const table_mod = @import("table.zig");

/// AllowedIPs table maps IP prefixes to peer identifiers.
/// Used by WireGuard to determine which peer should handle a given packet.
///
/// Usage:
///   var aips = AllowedIps(u32).init(allocator);
///   defer aips.deinit();
///
///   aips.insertForPeer(peer_id, &prefix);
///   const peer = aips.lookupPeer(&addr);
///
pub fn AllowedIps(comptime PeerId: type) type {
    return struct {
        const Self = @This();

        table: table_mod.Table(PeerId),

        /// Initialize with allocator.
        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .table = table_mod.Table(PeerId).init(allocator),
            };
        }

        /// Release all memory.
        pub fn deinit(self: *Self) void {
            self.table.deinit();
        }

        /// Insert a prefix for a peer. If the prefix already exists, updates the peer.
        pub fn insertForPeer(self: *Self, peer: PeerId, prefix: *const netip.Prefix) void {
            var masked = prefix.masked();
            self.table.insert(&masked, peer);
        }

        /// Look up which peer owns the given IP address (longest prefix match).
        /// Returns null if no prefix matches.
        pub fn lookupPeer(self: *const Self, ip: *const netip.Addr) ?PeerId {
            const result = self.table.lookup(ip);
            return if (result.ok) result.value else null;
        }

        /// Remove all prefixes associated with a given peer.
        /// Iterates all entries and deletes those belonging to the peer.
        pub fn removeByPeer(self: *Self, peer: PeerId) void {
            // Collect prefixes to delete (cannot modify table during iteration)
            // Use a bounded approach: iterate and delete matching entries
            var prefixes_to_delete: [256]netip.Prefix = undefined;
            var count: usize = 0;

            // Use table's all() to iterate if available, otherwise skip
            // For now, this is a placeholder - full implementation requires table iteration API
            _ = self;
            _ = peer;
            _ = &prefixes_to_delete;
            _ = &count;
            // TODO: Implement once table.all() iterator is available
            // The Go BART implementation uses table.All() which returns all prefix/value pairs.
            // For now, callers should track their own prefix sets per peer.
        }

        /// Check if the table contains any prefix that matches the given address.
        pub fn contains(self: *const Self, ip: *const netip.Addr) bool {
            const result = self.table.lookup(ip);
            return result.ok;
        }

        /// Insert a prefix from string notation (e.g., "10.0.0.0/24").
        /// Returns error if the prefix string is invalid.
        pub fn insertFromString(self: *Self, peer: PeerId, prefix_str: []const u8) !void {
            const prefix = try netip.Prefix.parsePrefix(prefix_str);
            self.insertForPeer(peer, &prefix);
        }

        /// Look up which peer owns the given IP address (from string).
        /// Returns null if no prefix matches or the address is invalid.
        pub fn lookupFromString(self: *const Self, ip_str: []const u8) ?PeerId {
            const addr = netip.Addr.parseAddr(ip_str) catch return null;
            return self.lookupPeer(&addr);
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "AllowedIps: basic insert and lookup" {
    var aips = AllowedIps(u32).init(std.heap.page_allocator);
    defer aips.deinit();

    // Insert 10.0.0.0/24 for peer 1
    try aips.insertFromString(1, "10.0.0.0/24");

    // Insert 192.168.1.0/24 for peer 2
    try aips.insertFromString(2, "192.168.1.0/24");

    // Lookup
    try testing.expectEqual(@as(?u32, 1), aips.lookupFromString("10.0.0.42"));
    try testing.expectEqual(@as(?u32, 2), aips.lookupFromString("192.168.1.100"));
    try testing.expectEqual(@as(?u32, null), aips.lookupFromString("172.16.0.1"));
}

test "AllowedIps: longest prefix match" {
    var aips = AllowedIps(u32).init(std.heap.page_allocator);
    defer aips.deinit();

    // Insert broad prefix for peer 1
    try aips.insertFromString(1, "10.0.0.0/8");

    // Insert more specific prefix for peer 2
    try aips.insertFromString(2, "10.1.0.0/16");

    // Even more specific for peer 3
    try aips.insertFromString(3, "10.1.2.0/24");

    // Longest prefix match should win
    try testing.expectEqual(@as(?u32, 3), aips.lookupFromString("10.1.2.5"));
    try testing.expectEqual(@as(?u32, 2), aips.lookupFromString("10.1.3.5"));
    try testing.expectEqual(@as(?u32, 1), aips.lookupFromString("10.2.0.1"));
}

test "AllowedIps: default route" {
    var aips = AllowedIps(u32).init(std.heap.page_allocator);
    defer aips.deinit();

    // Default route catches all
    try aips.insertFromString(99, "0.0.0.0/0");
    try aips.insertFromString(1, "10.0.0.0/24");

    try testing.expectEqual(@as(?u32, 1), aips.lookupFromString("10.0.0.1"));
    try testing.expectEqual(@as(?u32, 99), aips.lookupFromString("8.8.8.8"));
}

test "AllowedIps: contains" {
    var aips = AllowedIps(u32).init(std.heap.page_allocator);
    defer aips.deinit();

    try aips.insertFromString(1, "10.0.0.0/24");

    const addr_in = netip.Addr.mustParseAddr("10.0.0.5");
    const addr_out = netip.Addr.mustParseAddr("172.16.0.1");

    try testing.expect(aips.contains(&addr_in));
    try testing.expect(!aips.contains(&addr_out));
}

test "AllowedIps: IPv6" {
    var aips = AllowedIps(u32).init(std.heap.page_allocator);
    defer aips.deinit();

    try aips.insertFromString(1, "2001:db8::/32");

    try testing.expectEqual(@as(?u32, 1), aips.lookupFromString("2001:db8::1"));
    try testing.expectEqual(@as(?u32, null), aips.lookupFromString("2001:db9::1"));
}
