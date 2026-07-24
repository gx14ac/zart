// Copyright (c) 2024 ZART Project
// SPDX-License-Identifier: MIT

const std = @import("std");

/// Go BART: netip.Addr equivalent
pub const Addr = struct {
    octets: [16]u8,  // IPv6 address (IPv4 can be mapped to IPv6)
    
    /// Go BART: func (ip Addr) AsSlice() []byte
    pub fn asSlice(self: *const Addr) []const u8 {
        // IPv4 addresses are mapped to IPv6 bytes 12-15
        if (self.is4()) {
            return self.octets[12..16];
        } else {
            return &self.octets;
        }
    }
    
    /// Go BART: func (ip Addr) IsValid() bool
    pub fn isValid(self: *const Addr) bool {
        // For simplicity, consider all addresses valid for now
        // TODO: Implement proper validation logic
        _ = self;
        return true;
    }
    
    /// Check if this is an IPv4 address
    pub fn is4(self: *const Addr) bool {
        // IPv4 addresses are mapped to IPv6 with ::ffff: prefix
        return std.mem.eql(u8, self.octets[0..10], &[_]u8{0, 0, 0, 0, 0, 0, 0, 0, 0, 0}) and
               std.mem.eql(u8, self.octets[10..12], &[_]u8{0xff, 0xff});
    }
    
    /// Go BART: func (ip Addr) Prefix(int) netip.Prefix
    /// Create a prefix from this address with the specified prefix length
    pub fn prefix(self: *const Addr, prefix_len: u8) Prefix {
        return Prefix{
            .address = self.*,
            .prefix_len = prefix_len,
        };
    }
    
    /// Initialize from IPv4 address (mapped to IPv6)
    pub fn fromIPv4(a: u8, b: u8, c: u8, d: u8) Addr {
        return Addr{
            .octets = [16]u8{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, a, b, c, d},
        };
    }
    
    /// Initialize from IPv6 address
    pub fn fromIPv6(octets: [16]u8) Addr {
        return Addr{ .octets = octets };
    }

    /// Go BART: func ParseAddr(s string) (Addr, error)
    /// Parse IP address from string
    pub fn parseAddr(s: []const u8) !Addr {
        // Check for IPv4 or IPv6 by looking for characteristic characters
        for (s) |c| {
            switch (c) {
                '.' => return parseIPv4(s),
                ':' => return parseIPv6(s),
                '%' => return error.MissingIPv6Address, // Zone specifier without address
                else => continue,
            }
        }
        return error.UnableToParseIP;
    }

    /// Go BART: func MustParseAddr(s string) Addr
    /// Parse IP address from string and panic on error (for tests)
    pub fn mustParseAddr(s: []const u8) Addr {
        return parseAddr(s) catch |err| {
            std.debug.panic("Failed to parse IP address '{s}': {}", .{ s, err });
        };
    }

    /// Parse IPv4 address from string (e.g., "192.168.1.1")
    fn parseIPv4(s: []const u8) !Addr {
        var parts: [4]u8 = undefined;
        var part_index: usize = 0;
        var start: usize = 0;
        
        for (s, 0..) |c, i| {
            if (c == '.' or i == s.len - 1) {
                if (part_index >= 4) return error.InvalidIPv4;
                
                const end = if (c == '.') i else i + 1;
                const part_str = s[start..end];
                if (part_str.len == 0 or part_str.len > 3) return error.InvalidIPv4;
                
                const part = std.fmt.parseInt(u8, part_str, 10) catch return error.InvalidIPv4;
                parts[part_index] = part;
                part_index += 1;
                start = i + 1;
            }
        }
        
        if (part_index != 4) return error.InvalidIPv4;
        return Addr.fromIPv4(parts[0], parts[1], parts[2], parts[3]);
    }

    /// Parse IPv6 address from string (RFC 5952 compliant).
    /// Supports full form (8 groups), compressed (::), and IPv4-mapped (::ffff:1.2.3.4).
    /// Zone identifiers (%eth0) are stripped and ignored.
    fn parseIPv6(s: []const u8) !Addr {
        // Strip zone identifier if present
        var input = s;
        for (s, 0..) |c, i| {
            if (c == '%') {
                input = s[0..i];
                break;
            }
        }

        if (input.len == 0) return error.InvalidIPv6;

        var octets = [_]u8{0} ** 16;
        var group_count: usize = 0; // number of groups parsed before ::
        var post_groups: usize = 0; // number of groups parsed after ::
        var expand_pos: ?usize = null; // byte position where :: expansion goes
        var pos: usize = 0; // current byte write position (0..16, step 2)
        var i: usize = 0;

        // Handle leading ::
        if (input.len >= 2 and input[0] == ':' and input[1] == ':') {
            expand_pos = 0;
            i = 2;
            if (i == input.len) {
                // "::" = all zeros
                return Addr.fromIPv6(octets);
            }
        }

        while (i < input.len) {
            // Check for IPv4-mapped suffix (can appear after :: or after at least one group)
            if (pos <= 12 and (expand_pos != null or group_count >= 1)) {
                if (parseIPv4Tail(input[i..])) |ipv4_bytes| {
                    if (pos > 12) return error.InvalidIPv6;
                    // Write IPv4 bytes at current position (they take 4 bytes = 2 groups)
                    octets[pos] = ipv4_bytes[0];
                    octets[pos + 1] = ipv4_bytes[1];
                    octets[pos + 2] = ipv4_bytes[2];
                    octets[pos + 3] = ipv4_bytes[3];
                    pos += 4;
                    if (expand_pos != null) {
                        post_groups += 2;
                    } else {
                        group_count += 2;
                    }
                    i = input.len; // consumed rest
                    break;
                }
            }

            // Parse one hex group (1-4 hex digits)
            const group_start = i;
            var value: u16 = 0;
            var digits: usize = 0;
            while (i < input.len) : (i += 1) {
                const c = input[i];
                const digit = switch (c) {
                    '0'...'9' => c - '0',
                    'a'...'f' => c - 'a' + 10,
                    'A'...'F' => c - 'A' + 10,
                    else => break,
                };
                if (digits >= 4) return error.InvalidIPv6;
                value = (value << 4) | @as(u16, digit);
                digits += 1;
            }

            if (digits == 0) {
                // No digits found — only valid if we just processed :: at start
                if (group_start == 0 and expand_pos != null) break;
                return error.InvalidIPv6;
            }

            if (pos >= 16) return error.InvalidIPv6;
            octets[pos] = @intCast(value >> 8);
            octets[pos + 1] = @intCast(value & 0xFF);
            pos += 2;
            if (expand_pos != null) {
                post_groups += 1;
            } else {
                group_count += 1;
            }

            // Check what follows
            if (i >= input.len) break;

            if (input[i] == ':') {
                i += 1;
                if (i < input.len and input[i] == ':') {
                    // Found ::
                    if (expand_pos != null) return error.InvalidIPv6; // double ::
                    expand_pos = pos;
                    i += 1;
                    if (i == input.len) break;
                } else {
                    // Single colon — next group follows
                    if (i == input.len) return error.InvalidIPv6; // trailing :
                }
            } else {
                return error.InvalidIPv6; // unexpected character
            }
        }

        // Expand :: into zeros
        if (expand_pos) |ep| {
            const total_groups = group_count + post_groups;
            if (total_groups > 8) return error.InvalidIPv6;
            const missing_bytes = 16 - (total_groups * 2);
            // Shift post-:: groups to the right
            const post_bytes = post_groups * 2;
            if (post_bytes > 0) {
                // Move bytes from [ep..ep+post_bytes] to [ep+missing_bytes..ep+missing_bytes+post_bytes]
                var j: usize = post_bytes;
                while (j > 0) {
                    j -= 1;
                    octets[ep + missing_bytes + j] = octets[ep + j];
                }
            }
            // Zero-fill the gap
            @memset(octets[ep .. ep + missing_bytes], 0);
        } else {
            // No :: : must have exactly 8 groups (16 bytes)
            if (pos != 16) return error.InvalidIPv6;
        }

        return Addr.fromIPv6(octets);
    }

    /// Try to parse an IPv4 address at the tail of an IPv6 string.
    /// Returns null if the string does not look like an IPv4 address.
    fn parseIPv4Tail(s: []const u8) ?[4]u8 {
        // Quick check: must contain a dot
        var has_dot = false;
        for (s) |c| {
            if (c == '.') {
                has_dot = true;
                break;
            }
        }
        if (!has_dot) return null;

        var parts: [4]u8 = undefined;
        var part_index: usize = 0;
        var start: usize = 0;

        for (s, 0..) |c, idx| {
            if (c == '.' or idx == s.len - 1) {
                if (part_index >= 4) return null;
                const end = if (c == '.') idx else idx + 1;
                const part_str = s[start..end];
                if (part_str.len == 0 or part_str.len > 3) return null;
                parts[part_index] = std.fmt.parseInt(u8, part_str, 10) catch return null;
                part_index += 1;
                start = idx + 1;
            } else if (c < '0' or c > '9') {
                return null;
            }
        }
        if (part_index != 4) return null;
        return parts;
    }
};

/// Go BART: netip.Prefix equivalent  
pub const Prefix = struct {
    address: Addr,    // Go BART: addr netip.Addr
    prefix_len: u8,   // Go BART: bits int

    /// Go BART: func (p Prefix) Addr() netip.Addr
    pub fn addr(self: *const Prefix) Addr {
        return self.address;
    }
    
    /// Go BART: func (p Prefix) Bits() int
    pub fn bits(self: *const Prefix) u8 {
        return self.prefix_len;
    }
    
    /// Go BART: func (p Prefix) IsValid() bool
    pub fn isValid(self: *const Prefix) bool {
        // Check if prefix length is valid for the IP version
        if (self.is4()) {
            return self.prefix_len <= 32;
        } else {
            return self.prefix_len <= 128;
        }
    }
    
    /// Go BART: func (p Prefix) Masked() netip.Prefix
    pub fn masked(self: *const Prefix) Prefix {
        var masked_addr = self.address;

        const start_offset: u8 = if (self.is4()) 12 else 0;
        const addr_len: u8 = if (self.is4()) 4 else 16;

        const full_bytes = self.prefix_len / 8;
        const remaining_bits = self.prefix_len % 8;

        if (full_bytes < addr_len) {
            // Apply partial mask to the boundary byte first
            if (remaining_bits > 0) {
                const byte_idx = start_offset + full_bytes;
                if (byte_idx < 16) {
                    const mask = (@as(u8, 0xFF) << @intCast(8 - remaining_bits));
                    masked_addr.octets[byte_idx] &= mask;
                }
            }

            // Clear all bytes strictly after the boundary byte
            const clear_start = start_offset + full_bytes + @as(u8, if (remaining_bits > 0) 1 else 0);
            const clear_end = start_offset + addr_len;
            if (clear_start < clear_end) {
                @memset(masked_addr.octets[clear_start..clear_end], 0);
            }
        }

        return Prefix{
            .address = masked_addr,
            .prefix_len = self.prefix_len,
        };
    }
    
    /// Go BART: func (p Prefix) Contains(ip netip.Addr) bool
    pub fn contains(self: *const Prefix, ip: *const Addr) bool {
        // Both prefix and IP must be the same version (IPv4 or IPv6)
        if (self.is4() != ip.is4()) {
            return false;
        }
        
        // Check if the given IP address is within this prefix
        const prefix_octets = self.address.asSlice();
        const ip_octets = ip.asSlice();
        
        // Calculate how many complete bytes and remaining bits to check
        const full_bytes = self.prefix_len / 8;
        const remaining_bits = self.prefix_len % 8;
        
        // Check complete bytes
        if (full_bytes > 0 and full_bytes <= prefix_octets.len) {
            if (!std.mem.eql(u8, prefix_octets[0..full_bytes], ip_octets[0..full_bytes])) {
                return false;
            }
        }
        
        // Check remaining bits in the last byte
        if (remaining_bits > 0 and full_bytes < prefix_octets.len) {
            const mask = (@as(u8, 0xFF) << @intCast(8 - remaining_bits));
            const prefix_masked = prefix_octets[full_bytes] & mask;
            const ip_masked = ip_octets[full_bytes] & mask;
            if (prefix_masked != ip_masked) {
                return false;
            }
        }
        
        return true;
    }
    
    /// Check if this prefix contains the IP address of another prefix
    /// Used in LookupPrefixLPM for leaf node containment check
    pub fn containsAddr(self: *const Prefix, other_prefix: *const Prefix) bool {
        return self.contains(&other_prefix.address);
    }
    
    /// Check if this prefix length is greater than another
    pub fn bitsGreaterThan(self: *const Prefix, other_bits: u8) bool {
        return self.prefix_len > other_bits;
    }
    
    /// Go BART: func (p Prefix) Overlaps(other netip.Prefix) bool
    /// Check if this prefix overlaps with another prefix
    pub fn overlaps(self: *const Prefix, other: *const Prefix) bool {
        // Both prefixes must be the same version (IPv4 or IPv6)
        if (self.is4() != other.is4()) {
            return false;
        }
        
        // Two prefixes overlap if they have a common network portion
        // Use the shorter prefix length to determine the comparison scope
        const min_bits = @min(self.prefix_len, other.prefix_len);
        
        // Compare network portions using the shorter prefix length
        const self_octets = self.address.asSlice();
        const other_octets = other.address.asSlice();
        
        // Calculate how many complete bytes and remaining bits to check
        const full_bytes = min_bits / 8;
        const remaining_bits = min_bits % 8;
        
        // Check complete bytes
        if (full_bytes > 0 and full_bytes <= self_octets.len) {
            if (!std.mem.eql(u8, self_octets[0..full_bytes], other_octets[0..full_bytes])) {
                return false;
            }
        }
        
        // Check remaining bits in the last byte
        if (remaining_bits > 0 and full_bytes < self_octets.len) {
            const mask = (@as(u8, 0xFF) << @intCast(8 - remaining_bits));
            const self_masked = self_octets[full_bytes] & mask;
            const other_masked = other_octets[full_bytes] & mask;
            if (self_masked != other_masked) {
                return false;
            }
        }
        
        return true;
    }
    
    /// Check if this is an IPv4 prefix
    pub fn is4(self: *const Prefix) bool {
        // IPv4 addresses are mapped to IPv6 with ::ffff: prefix
        return std.mem.eql(u8, self.address.octets[0..10], &[_]u8{0, 0, 0, 0, 0, 0, 0, 0, 0, 0}) and
               std.mem.eql(u8, self.address.octets[10..12], &[_]u8{0xff, 0xff});
    }
    
    /// Initialize from IPv4 prefix
    pub fn fromIPv4(a: u8, b: u8, c: u8, d: u8, prefix_len: u8) Prefix {
        return Prefix{
            .address = Addr.fromIPv4(a, b, c, d),
            .prefix_len = prefix_len,
        };
    }
    
    /// Initialize from IPv6 prefix
    pub fn fromIPv6(octets: [16]u8, prefix_len: u8) Prefix {
        return Prefix{
            .address = Addr.fromIPv6(octets),
            .prefix_len = prefix_len,
        };
    }
    
    /// Check if two prefixes are equal (Go BART: kid.prefix == pfx)
    pub fn eql(self: *const Prefix, other: *const Prefix) bool {
        if (self.prefix_len != other.prefix_len) return false;
        return std.mem.eql(u8, &self.address.octets, &other.address.octets);
    }

    /// Go BART: func ParsePrefix(s string) (Prefix, error)
    /// Parse prefix from string (e.g., "192.168.1.0/24")
    pub fn parsePrefix(s: []const u8) !Prefix {
        // Find the '/' separator
        var slash_pos: ?usize = null;
        for (s, 0..) |c, i| {
            if (c == '/') {
                slash_pos = i;
                break;
            }
        }
        
        const slash_idx = slash_pos orelse return error.MissingSlash;
        
        const addr_str = s[0..slash_idx];
        const bits_str = s[slash_idx + 1..];
        
        const parsed_addr = try Addr.parseAddr(addr_str);
        const prefix_len = std.fmt.parseInt(u8, bits_str, 10) catch return error.InvalidPrefixLength;
        
        // Validate prefix length
        if (parsed_addr.is4()) {
            if (prefix_len > 32) return error.InvalidIPv4PrefixLength;
        } else {
            if (prefix_len > 128) return error.InvalidIPv6PrefixLength;
        }
        
        return Prefix{
            .address = parsed_addr,
            .prefix_len = prefix_len,
        };
    }

    /// Go BART: func MustParsePrefix(s string) Prefix
    /// Parse prefix from string and panic on error (for tests)
    pub fn mustParsePrefix(s: []const u8) Prefix {
        return parsePrefix(s) catch |err| {
            std.debug.panic("Failed to parse prefix '{s}': {}", .{ s, err });
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "parseIPv6: loopback ::1" {
    const addr = try Addr.parseAddr("::1");
    const expected = [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    try testing.expectEqualSlices(u8, &expected, &addr.octets);
}

test "parseIPv6: all zeros ::" {
    const addr = try Addr.parseAddr("::");
    const expected = [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectEqualSlices(u8, &expected, &addr.octets);
}

test "parseIPv6: full form 2001:0db8:0000:0000:0000:0000:0000:0001" {
    const addr = try Addr.parseAddr("2001:0db8:0000:0000:0000:0000:0000:0001");
    const expected = [16]u8{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    try testing.expectEqualSlices(u8, &expected, &addr.octets);
}

test "parseIPv6: compressed 2001:db8::1" {
    const addr = try Addr.parseAddr("2001:db8::1");
    const expected = [16]u8{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    try testing.expectEqualSlices(u8, &expected, &addr.octets);
}

test "parseIPv6: ff:aaaa::1 (single-byte groups)" {
    const addr = try Addr.parseAddr("ff:aaaa::1");
    // ff = 0x00ff, aaaa = 0xaaaa
    const expected = [16]u8{ 0x00, 0xff, 0xaa, 0xaa, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    try testing.expectEqualSlices(u8, &expected, &addr.octets);
}

test "parseIPv6: ffff:bbbb::5" {
    const addr = try Addr.parseAddr("ffff:bbbb::5");
    const expected = [16]u8{ 0xff, 0xff, 0xbb, 0xbb, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5 };
    try testing.expectEqualSlices(u8, &expected, &addr.octets);
}

test "parseIPv6: fe80::1%eth0 (zone ID stripped)" {
    const addr = try Addr.parseAddr("fe80::1%eth0");
    const expected = [16]u8{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    try testing.expectEqualSlices(u8, &expected, &addr.octets);
}

test "parseIPv6: all ones ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff" {
    const addr = try Addr.parseAddr("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff");
    const expected = [_]u8{0xff} ** 16;
    try testing.expectEqualSlices(u8, &expected, &addr.octets);
}

test "parseIPv6: middle compression 2001:db8::ff00:42:8329" {
    const addr = try Addr.parseAddr("2001:db8::ff00:42:8329");
    const expected = [16]u8{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0xff, 0x00, 0x00, 0x42, 0x83, 0x29 };
    try testing.expectEqualSlices(u8, &expected, &addr.octets);
}

test "parseIPv6: IPv4-mapped ::ffff:192.168.1.1" {
    const addr = try Addr.parseAddr("::ffff:192.168.1.1");
    const expected = [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 168, 1, 1 };
    try testing.expectEqualSlices(u8, &expected, &addr.octets);
}

test "parseIPv6: rejects double ::" {
    const result = Addr.parseAddr("2001::db8::1");
    try testing.expectError(error.InvalidIPv6, result);
}

test "parseIPv6: rejects too many groups" {
    const result = Addr.parseAddr("1:2:3:4:5:6:7:8:9");
    try testing.expectError(error.InvalidIPv6, result);
}

test "parseIPv4: basic" {
    const addr = try Addr.parseAddr("10.0.0.1");
    try testing.expect(addr.is4());
    try testing.expectEqual(@as(u8, 10), addr.octets[12]);
    try testing.expectEqual(@as(u8, 0), addr.octets[13]);
    try testing.expectEqual(@as(u8, 0), addr.octets[14]);
    try testing.expectEqual(@as(u8, 1), addr.octets[15]);
}

test "parsePrefix: IPv6 prefix" {
    const pfx = try Prefix.parsePrefix("2001:db8::/32");
    try testing.expectEqual(@as(u8, 32), pfx.prefix_len);
    try testing.expectEqual(@as(u8, 0x20), pfx.address.octets[0]);
    try testing.expectEqual(@as(u8, 0x01), pfx.address.octets[1]);
    try testing.expectEqual(@as(u8, 0x0d), pfx.address.octets[2]);
    try testing.expectEqual(@as(u8, 0xb8), pfx.address.octets[3]);
}
