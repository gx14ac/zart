const std = @import("std");

/// LookupResult represents the result of a lookup operation
pub fn LookupResult(comptime V: type) type {
    return struct {
        prefix: Prefix,
        value: V,
        ok: bool,
    };
}

/// leafNode is a prefix with value, used as a path compressed child.
pub fn LeafNode(comptime V: type) type {
    return struct {
        const Self = @This();

        prefix: Prefix,
        value: V,

        pub fn init(prefix: Prefix, value: V) Self {
            return Self{ .prefix = prefix, .value = value };
        }

        /// cloneLeaf returns a clone of the leaf
        /// if the value implements the Cloner interface.
        pub fn cloneLeaf(self: *const Self) Self {
            return Self{ .prefix = self.prefix, .value = self.value };
        }
    };
}

/// fringeNode is a path-compressed leaf with value but without a prefix.
/// The prefix of a fringe is solely defined by the position in the trie.
/// The fringe-compression (no stored prefix) saves a lot of memory,
/// but the algorithm is more complex.
pub fn FringeNode(comptime V: type) type {
    return struct {
        const Self = @This();

        value: V,

        pub fn init(value: V) Self {
            return Self{ .value = value };
        }

        /// cloneFringe returns a clone of the fringe
        /// if the value implements the Cloner interface.
        pub fn cloneFringe(self: *const Self) Self {
            return Self{ .value = self.value };
        }
    };
}

/// Child represents either a node, leaf, or fringe
pub fn Child(comptime V: type) type {
    return union(enum) {
        node: *anyopaque, // DirectNode pointer
        leaf: LeafNode(V),
        fringe: FringeNode(V),
    };
}

/// Prefix represents an IP prefix with address and bit length
pub const Prefix = struct {
    addr: IPAddr,
    bits: u8,

    /// Parse a CIDR notation string into a Prefix
    pub fn parse(cidr_str: []const u8) !Prefix {
        const slash_pos = std.mem.indexOf(u8, cidr_str, "/") orelse return error.InvalidCIDR;

        const addr_str = cidr_str[0..slash_pos];
        const bits_str = cidr_str[slash_pos + 1 ..];

        const bits = try std.fmt.parseInt(u8, bits_str, 10);

        // Try to parse as IPv4 first, then IPv6
        if (IPAddr.parseIPv4(addr_str)) |addr| {
            if (bits > 32) return error.InvalidPrefixLength;
            return Prefix{ .addr = addr, .bits = bits };
        } else |_| {
            const addr = try IPAddr.parseIPv6(addr_str);
            if (bits > 128) return error.InvalidPrefixLength;
            return Prefix{ .addr = addr, .bits = bits };
        }
    }

    pub fn init(addr: *const IPAddr, bits: u8) Prefix {
        const pfx = Prefix{ .addr = addr.*, .bits = bits };
        return pfx;
    }

    pub fn eql(self: Prefix, other: Prefix) bool {
        return self.addr.eql(other.addr) and self.bits == other.bits;
    }

    /// isValid checks if the prefix is valid
    pub fn isValid(self: Prefix) bool {
        switch (self.addr) {
            .v4 => return self.bits <= 32,
            .v6 => return self.bits <= 128,
        }
    }

    /// masked returns the canonical form of the prefix
    pub fn masked(self: *const Prefix) Prefix {
        if (!self.isValid()) return self.*;
        const masked_addr = self.addr.masked(self.bits);
        return Prefix.init(&masked_addr, self.bits);
    }

    /// 指定アドレスがこのプレフィックスに含まれるか判定
    pub fn containsAddr(self: Prefix, addr: IPAddr) bool {
        // bits長でマスクして比較
        const masked_addr = addr.masked(self.bits);
        return self.addr.eql(masked_addr);
    }

    /// overlaps checks if this prefix overlaps with another prefix
    /// Go実装のPrefix.Overlapsメソッドを移植
    pub fn overlaps(self: *const Prefix, other: *const Prefix) bool {
        // 短い方のプレフィックス長を使用
        const min_bits = if (self.bits < other.bits) self.bits else other.bits;

        // 両方のアドレスを短い方の長さでマスク
        const self_masked = self.addr.masked(min_bits);
        const other_masked = other.addr.masked(min_bits);

        // マスクされたアドレスが同じならオーバーラップ
        return self_masked.eql(other_masked);
    }

    /// Format function for std.debug.print - CIDR notation
    pub fn format(self: Prefix, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        switch (self.addr) {
            .v4 => |v4| {
                try writer.print("{}.{}.{}.{}/{}", .{ v4[0], v4[1], v4[2], v4[3], self.bits });
            },
            .v6 => |v6| {
                // IPv6のCIDR表記を作成
                try writer.print("{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}/{}", .{ v6[0], v6[1], v6[2], v6[3], v6[4], v6[5], v6[6], v6[7], v6[8], v6[9], v6[10], v6[11], v6[12], v6[13], v6[14], v6[15], self.bits });
            },
        }
    }
};

/// IPAddr represents an IPv4 or IPv6 address
pub const IPAddr = union(enum) {
    v4: [4]u8,
    v6: [16]u8,

    /// Parse IPv4 address from string like "192.168.1.1"
    pub fn parseIPv4(addr_str: []const u8) !IPAddr {
        var parts = std.mem.splitScalar(u8, addr_str, '.');
        var addr_octets: [4]u8 = undefined;

        for (0..4) |i| {
            const part = parts.next() orelse return error.InvalidIPv4;
            addr_octets[i] = try std.fmt.parseInt(u8, part, 10);
        }

        if (parts.next() != null) return error.InvalidIPv4; // Too many parts

        return IPAddr{ .v4 = addr_octets };
    }

    /// Parse IPv6 address from string like "2001:db8::1"
    /// Go BART完全互換のIPv6パーサー
    pub fn parseIPv6(addr_str: []const u8) !IPAddr {
        var result: [16]u8 = std.mem.zeroes([16]u8);

        // Handle "::" compression
        if (std.mem.indexOf(u8, addr_str, "::")) |double_colon_pos| {
            const left_part = addr_str[0..double_colon_pos];
            const right_part = addr_str[double_colon_pos + 2 ..];

            var left_groups: usize = 0;
            var right_groups: usize = 0;

            // Parse left part
            if (left_part.len > 0) {
                var left_iter = std.mem.splitScalar(u8, left_part, ':');
                while (left_iter.next()) |group| {
                    if (group.len == 0) continue;
                    if (left_groups >= 8) return error.InvalidIPv6;
                    const value = try std.fmt.parseInt(u16, group, 16);
                    result[left_groups * 2] = @as(u8, @intCast(value >> 8));
                    result[left_groups * 2 + 1] = @as(u8, @intCast(value & 0xff));
                    left_groups += 1;
                }
            }

            // Parse right part
            if (right_part.len > 0) {
                var right_iter = std.mem.splitScalar(u8, right_part, ':');
                var right_parts = std.ArrayList(u16).init(std.heap.page_allocator);
                defer right_parts.deinit();

                while (right_iter.next()) |group| {
                    if (group.len == 0) continue;
                    const value = try std.fmt.parseInt(u16, group, 16);
                    try right_parts.append(value);
                }

                right_groups = right_parts.items.len;

                // Fill right part from the end
                for (0..right_groups) |i| {
                    const pos = (8 - right_groups + i) * 2;
                    const value = right_parts.items[i];
                    result[pos] = @as(u8, @intCast(value >> 8));
                    result[pos + 1] = @as(u8, @intCast(value & 0xff));
                }
            }

            // Verify total groups don't exceed 8
            if (left_groups + right_groups > 8) return error.InvalidIPv6;

            return IPAddr{ .v6 = result };
        }

        // Handle full address without compression
        var groups: usize = 0;
        var iter = std.mem.splitScalar(u8, addr_str, ':');

        while (iter.next()) |group| {
            if (group.len == 0) return error.InvalidIPv6;
            if (groups >= 8) return error.InvalidIPv6;

            const value = try std.fmt.parseInt(u16, group, 16);
            result[groups * 2] = @as(u8, @intCast(value >> 8));
            result[groups * 2 + 1] = @as(u8, @intCast(value & 0xff));
            groups += 1;
        }

        if (groups != 8) return error.InvalidIPv6;

        return IPAddr{ .v6 = result };
    }

    /// Check if this is an IPv4 address
    pub fn isIPv4(self: IPAddr) bool {
        return switch (self) {
            .v4 => true,
            .v6 => false,
        };
    }

    /// Get octets as slice (for IPv4: 4 bytes, for IPv6: 16 bytes)
    pub fn octets(self: IPAddr) []const u8 {
        switch (self) {
            .v4 => |v4| {
                // Create a static buffer to avoid stack corruption
                const static = struct {
                    var buf: [4]u8 = undefined;
                };
                static.buf = v4;
                return static.buf[0..];
            },
            .v6 => |v6| {
                // Create a static buffer for IPv6
                const static = struct {
                    var buf: [16]u8 = undefined;
                };
                static.buf = v6;
                return static.buf[0..];
            },
        }
    }

    pub fn eql(self: IPAddr, other: IPAddr) bool {
        switch (self) {
            .v4 => |self_v4| {
                switch (other) {
                    .v4 => |other_v4| return std.mem.eql(u8, &self_v4, &other_v4),
                    .v6 => return false,
                }
            },
            .v6 => |self_v6| {
                switch (other) {
                    .v4 => return false,
                    .v6 => |other_v6| return std.mem.eql(u8, &self_v6, &other_v6),
                }
            },
        }
    }

    /// Format function for std.debug.print
    pub fn format(self: IPAddr, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .v4 => |v4| {
                try writer.print("{}.{}.{}.{}", .{ v4[0], v4[1], v4[2], v4[3] });
            },
            .v6 => |v6| {
                try writer.print("{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}", .{ v6[0], v6[1], v6[2], v6[3], v6[4], v6[5], v6[6], v6[7], v6[8], v6[9], v6[10], v6[11], v6[12], v6[13], v6[14], v6[15] });
            },
        }
    }

    /// masked applies a network mask to the address
    pub fn masked(self: IPAddr, bits: u8) IPAddr {
        switch (self) {
            .v4 => |v4| {
                if (bits == 0) {
                    return IPAddr{ .v4 = .{ 0, 0, 0, 0 } };
                }
                if (bits >= 32) {
                    return IPAddr{ .v4 = v4 };
                }
                const mask = @as(u32, 0xffffffff) << @as(u5, @intCast(32 - bits));
                const addr = std.mem.readInt(u32, &v4, .big);
                const masked_addr = addr & mask;
                var result: [4]u8 = undefined;
                std.mem.writeInt(u32, &result, masked_addr, .big);
                return IPAddr{ .v4 = result };
            },
            .v6 => |v6| {
                if (bits == 0) {
                    return IPAddr{ .v6 = .{0} ** 16 };
                }
                if (bits >= 128) {
                    return IPAddr{ .v6 = v6 };
                }

                // IPv6のマスク処理を実装
                var result: [16]u8 = v6;
                const full_bytes = bits / 8;
                const remaining_bits = bits % 8;

                // 完全なバイトのマスク
                var i: usize = full_bytes;
                while (i < 16) : (i += 1) {
                    result[i] = 0;
                }

                // 部分的なバイトのマスク
                if (remaining_bits > 0 and full_bytes < 16) {
                    const mask = @as(u8, 0xff) << @as(u3, @intCast(8 - remaining_bits));
                    result[full_bytes] &= mask;
                }

                return IPAddr{ .v6 = result };
            },
        }
    }

    /// Check if this IP address is valid (not zero)
    pub fn isValid(self: IPAddr) bool {
        return switch (self) {
            .v4 => |v4| !std.mem.eql(u8, &v4, &[_]u8{ 0, 0, 0, 0 }),
            .v6 => |v6| !std.mem.eql(u8, &v6, &[_]u8{0} ** 16),
        };
    }
};

/// Check if prefix is a fringe - HOT PATH: Force inline + Lookup Table
/// ZERO-ALLOC-OPTIMIZED: Uses precomputed lookup table for maximum performance
pub inline fn isFringe(depth: usize, bits: u8) bool {
    if (depth >= 32) return false; // Bounds check
    return isFringeLookupTable[depth][bits];
}

/// Precomputed isFringe lookup table
/// isFringeLookupTable[depth][bits] = isFringe(depth, bits)
/// Eliminates runtime modulo and comparison operations
pub const isFringeLookupTable = blk: {
    @setEvalBranchQuota(50000);
    var table: [32][256]bool = undefined;

    for (0..32) |depth| {
        for (0..256) |bits| {
            const max_depth = bits / 8;
            const last_bits = bits % 8;
            // Fix overflow: check max_depth > 0 before subtraction
            table[depth][bits] = (max_depth > 0) and (depth == max_depth - 1) and (last_bits == 0);
        }
    }

    break :blk table;
};
