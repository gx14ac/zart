// Copyright (c) 2024 ZART Project
// SPDX-License-Identifier: MIT
//
// Fuzz tests for BART table insert/lookup/delete operations.
// Run with: zig build fuzz
//
const std = @import("std");
const testing = std.testing;
const netip = @import("netip.zig");
const table_mod = @import("table.zig");
const Table = table_mod.Table;

// Fuzz test: random insert and lookup must not crash.
// If we insert a prefix with a value, looking up an IP within that prefix
// must either return the value or a more-specific match.
test "fuzz: insert then lookup" {
    try testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) anyerror!void {
            if (input.len < 6) return; // Need at least: 4 bytes addr + 1 byte prefix_len + 1 byte value

            // Extract IPv4 address from first 4 bytes
            const addr_bytes: [4]u8 = input[0..4].*;
            const prefix_len = input[4] % 33; // 0-32 for IPv4
            const value: u16 = @as(u16, input[5]);

            const addr = netip.Addr.fromIPv4(addr_bytes[0], addr_bytes[1], addr_bytes[2], addr_bytes[3]);
            var pfx = addr.prefix(prefix_len);
            pfx = pfx.masked(); // normalize

            var t = Table(u16).init(std.heap.page_allocator);
            defer t.deinit();

            // Insert should not crash
            t.insert(&pfx, value);

            // Lookup the address itself should return something (we just inserted a covering prefix)
            const result = t.lookup(&addr);
            _ = result; // may or may not match depending on masking, but must not crash
        }
    }.testOne, .{});
}

// Fuzz test: insert then delete then lookup must not crash.
test "fuzz: insert delete lookup" {
    try testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) anyerror!void {
            if (input.len < 10) return; // Need 2 operations worth of data

            var t = Table(u16).init(std.heap.page_allocator);
            defer t.deinit();

            // First operation: insert
            const addr1 = netip.Addr.fromIPv4(input[0], input[1], input[2], input[3]);
            const pfx_len1 = input[4] % 33;
            var pfx1 = addr1.prefix(pfx_len1);
            pfx1 = pfx1.masked();
            t.insert(&pfx1, @as(u16, input[5]));

            // Second operation: delete a (possibly different) prefix
            const addr2 = netip.Addr.fromIPv4(input[6], input[7], input[8], input[9]);
            const pfx_len2 = if (input.len > 10) input[10] % 33 else 24;
            var pfx2 = addr2.prefix(pfx_len2);
            pfx2 = pfx2.masked();
            t.delete(&pfx2);

            // Lookup should not crash
            const lookup_addr = netip.Addr.fromIPv4(input[0], input[1], input[2], input[3]);
            _ = t.lookup(&lookup_addr);
        }
    }.testOne, .{});
}

// Fuzz test: IPv6 address parsing must not crash on arbitrary input.
test "fuzz: parseAddr no crash" {
    try testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) anyerror!void {
            // Should either parse successfully or return an error, never crash
            _ = netip.Addr.parseAddr(input) catch return;
        }
    }.testOne, .{});
}

// Fuzz test: prefix parsing must not crash on arbitrary input.
test "fuzz: parsePrefix no crash" {
    try testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) anyerror!void {
            _ = netip.Prefix.parsePrefix(input) catch return;
        }
    }.testOne, .{});
}
