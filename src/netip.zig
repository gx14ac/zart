// Copyright (c) 2024 ZART Project
// SPDX-License-Identifier: MIT

const std = @import("std");

/// Go BART: netip.Addr equivalent
pub const Addr = struct {
    octets: [16]u8,  // IPv6 address (IPv4 can be mapped to IPv6)
    
    /// Go BART: func (ip Addr) AsSlice() []byte
    pub fn asSlice(self: *const Addr) []const u8 {
        return &self.octets;
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
        // For simplicity, return self for now
        // TODO: Implement proper masking logic
        return self.*;
    }
    
    /// Go BART: func (p Prefix) Contains(ip netip.Addr) bool
    pub fn contains(self: *const Prefix, ip: *const Addr) bool {
        // Check if the given IP address is within this prefix
        const prefix_octets = self.address.asSlice();
        const ip_octets = ip.asSlice();
        
        // Calculate how many complete bytes and remaining bits to check
        const full_bytes = self.prefix_len / 8;
        const remaining_bits = self.prefix_len % 8;
        
        // Check complete bytes
        if (full_bytes > 0) {
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
};
