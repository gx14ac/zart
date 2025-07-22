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
