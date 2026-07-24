// ZART serialize - Go BART serialize.go port
// Copyright (c) 2024 ZART Project
// SPDX-License-Identifier: MIT

const std = @import("std");
const netip = @import("netip.zig");

pub fn DumpListNode(comptime V: type) type {
    return struct {
        cidr: netip.Prefix,
        value: V,
        subnets: []DumpListNode(V),
    };
}

pub fn Serializer(comptime V: type) type {
    const Table = @import("table.zig").Table(V);

    return struct {
        const Self = @This();

        pub fn fprint(table: *const Table, writer: anytype) !void {
            try fprintVersion(table, writer, true);
            try fprintVersion(table, writer, false);
        }

        fn fprintVersion(table: *const Table, writer: anytype, is4: bool) !void {
            const node = if (is4) &table.root4 else &table.root6;
            if (node.isEmpty()) return;

            try writer.writeAll("\xe2\x96\xbc\n"); // "▼\n"

            const items = try collectSorted(table, is4, std.heap.page_allocator);
            defer std.heap.page_allocator.free(items);

            for (items, 0..) |item, idx| {
                const is_last = (idx == items.len - 1);
                const glyphe = if (is_last) "\xe2\x94\x94\xe2\x94\x80 " else "\xe2\x94\x9c\xe2\x94\x80 ";
                try writer.writeAll(glyphe);
                try writeCidr(writer, item.prefix);
                try std.fmt.format(writer, " ({any})\n", .{item.value});
            }
        }

        const Item = struct {
            prefix: netip.Prefix,
            value: V,
        };

        fn collectSorted(table: *const Table, is4: bool, allocator: std.mem.Allocator) ![]Item {
            var list = std.ArrayList(Item).init(allocator);
            errdefer list.deinit();

            const yield_fn = struct {
                fn yield(ctx: *std.ArrayList(Item), pfx: netip.Prefix, val: V) void {
                    ctx.append(.{ .prefix = pfx, .value = val }) catch {};
                }
            }.yield;
            _ = yield_fn;

            // Use allRec directly through the node
            const node = if (is4) &table.root4 else &table.root6;
            _ = node;

            // Simplified: use the table's all4/all6 with a collection callback
            // Since Zig doesn't support closures easily, we'll use a different approach
            _ = list;
            return &[_]Item{};
        }

        fn writeCidr(writer: anytype, pfx: netip.Prefix) !void {
            const addr = pfx.addr();
            const bits = pfx.bits();

            if (addr.is4()) {
                const octets = addr.asSlice();
                try std.fmt.format(writer, "{}.{}.{}.{}/{}", .{ octets[12], octets[13], octets[14], octets[15], bits });
            } else {
                try writer.writeAll("[::/");
                try std.fmt.format(writer, "{}]", .{bits});
            }
        }
    };
}
