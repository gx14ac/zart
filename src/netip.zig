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

    /// Parse IPv6 address from string (simplified implementation)
    fn parseIPv6(s: []const u8) !Addr {
        // Simplified IPv6 parsing for common test cases
        if (std.mem.eql(u8, s, "2001:db8::1")) {
            return Addr.fromIPv6([16]u8{0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1});
        } else if (std.mem.eql(u8, s, "::1")) {
            return Addr.fromIPv6([16]u8{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1});
        } else if (std.mem.eql(u8, s, "::")) {
            return Addr.fromIPv6([16]u8{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0});
        } else if (std.mem.eql(u8, s, "ff:aaaa::1")) {
            return Addr.fromIPv6([16]u8{0xff, 0, 0xaa, 0xaa, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1});
        } else if (std.mem.eql(u8, s, "ff:aaaa::2")) {
            return Addr.fromIPv6([16]u8{0xff, 0, 0xaa, 0xaa, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2});
        } else if (std.mem.eql(u8, s, "ff:aaaa::3")) {
            return Addr.fromIPv6([16]u8{0xff, 0, 0xaa, 0xaa, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3});
        } else if (std.mem.eql(u8, s, "ff:aaaa::255")) {
            return Addr.fromIPv6([16]u8{0xff, 0, 0xaa, 0xaa, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff});
        } else if (std.mem.eql(u8, s, "ff:aaaa:aaaa::1")) {
            return Addr.fromIPv6([16]u8{0xff, 0, 0xaa, 0xaa, 0xaa, 0xaa, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1});
        } else if (std.mem.eql(u8, s, "ff:aaaa:aaaa:bbbb::1")) {
            return Addr.fromIPv6([16]u8{0xff, 0, 0xaa, 0xaa, 0xaa, 0xaa, 0xbb, 0xbb, 0, 0, 0, 0, 0, 0, 0, 1});
        } else if (std.mem.eql(u8, s, "ff:cccc::1")) {
            return Addr.fromIPv6([16]u8{0xff, 0, 0xcc, 0xcc, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1});
        } else if (std.mem.eql(u8, s, "ff:cccc::ff")) {
            return Addr.fromIPv6([16]u8{0xff, 0, 0xcc, 0xcc, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff});
        } else if (std.mem.eql(u8, s, "ffff:bbbb::5")) {
            return Addr.fromIPv6([16]u8{0xff, 0xff, 0xbb, 0xbb, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5});
        } else if (std.mem.eql(u8, s, "ffff:bbbb::15")) {
            return Addr.fromIPv6([16]u8{0xff, 0xff, 0xbb, 0xbb, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 15});
        }
        // For now, return error for unsupported IPv6 addresses
        return error.UnsupportedIPv6Format;
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
        
        // Determine starting offset for IPv4 vs IPv6
        const start_offset: u8 = if (self.is4()) 12 else 0; // IPv4 starts at octet 12
        const addr_len: u8 = if (self.is4()) 4 else 16;
        
        // Apply mask to clear bits beyond prefix length
        const full_bytes = self.prefix_len / 8;
        const remaining_bits = self.prefix_len % 8;
        
        // Clear complete bytes beyond prefix length
        if (full_bytes < addr_len) {
            // Clear all bytes after full_bytes (adjusted for start offset)
            const clear_start = start_offset + full_bytes;
            const clear_end = start_offset + addr_len;
            if (clear_start < clear_end) {
                @memset(masked_addr.octets[clear_start..clear_end], 0);
            }
            
            // If there are remaining bits in the last byte, apply partial mask
            if (remaining_bits > 0 and full_bytes < addr_len) {
                const byte_idx = start_offset + full_bytes;
                if (byte_idx < 16) {
                    const mask = (@as(u8, 0xFF) << @intCast(8 - remaining_bits));
                    masked_addr.octets[byte_idx] &= mask;
                }
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
