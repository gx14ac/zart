const std = @import("std");
const Array256 = @import("sparse_array256.zig").Array256;
const base_index = @import("base_index.zig");
const bitset256 = @import("bitset256.zig");
const sparse_array256 = @import("sparse_array256.zig");
const node_pool = @import("node_pool.zig");
const lookup_tbl = @import("lookup_tbl.zig");

const stride_len = 8; // byte, a multibit trie with stride len 8
const max_tree_depth = 16; // max 16 bytes for IPv6
const max_items = 256; // max 256 prefixes or children in node

/// stridePath, max 16 octets deep
pub const StridePath = [max_tree_depth]u8;

/// node is a level node in the multibit-trie.
/// A node has prefixes and children, forming the multibit trie.
///
/// The prefixes, mapped by the baseIndex() function from the ART algorithm,
/// form a complete binary tree.
/// See the artlookup.pdf paper in the doc folder to understand the mapping function
/// and the binary tree of prefixes.
///
/// In contrast to the ART algorithm, sparse arrays (popcount-compressed slices)
/// are used instead of fixed-size arrays.
///
/// The array slots are also not pre-allocated (alloted) as described
/// in the ART algorithm, fast bitset operations are used to find the
/// longest-prefix-match.
///
/// The child array recursively spans the trie with a branching factor of 256
/// and also records path-compressed leaves in the free node slots.
pub fn Node(comptime V: type) type {
    return struct {
        const Self = @This();
        
        /// prefixes contains the routes, indexed as a complete binary tree with payload V
        /// with the help of the baseIndex mapping function from the ART algorithm.
        prefixes: Array256(V),
        
        /// children, recursively spans the trie with a branching factor of 256.
        children: Array256(Child(V)),
        
        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .prefixes = Array256(V).init(allocator),
                .children = Array256(Child(V)).init(allocator),
            };
        }
        
        pub fn deinit(self: *Self) void {
            self.prefixes.deinit();
            self.children.deinit();
        }
        
        /// isEmpty returns true if node has neither prefixes nor children
        pub fn isEmpty(self: *const Self) bool {
            return self.prefixes.len() == 0 and self.children.len() == 0;
        }
        
        /// insertAtDepth insert a prefix/val into a node tree at depth.
        /// n must not be nil, prefix must be valid and already in canonical form.
        pub fn insertAtDepth(self: *Self, pfx: *const Prefix, val: V, depth: usize, allocator: std.mem.Allocator) bool {
            // ここではpfxは既にmaskedされている前提
            const ip = &pfx.addr;
            const bits = pfx.bits;
            const octets = ip.asSlice();
            const max_depth = base_index.maxDepthAndLastBits(bits).max_depth;
            const last_bits = base_index.maxDepthAndLastBits(bits).last_bits;
            std.debug.print("insertAtDepth: bits={}, max_depth={}, last_bits={}, octets={any}\n", .{bits, max_depth, last_bits, octets});
            var current_depth = depth;
            var current_node = self;
            while (current_depth < max_depth) : (current_depth += 1) {
                var octet: u8 = 0;
                if (current_depth < octets.len) {
                    octet = octets[current_depth];
                }
                if (!current_node.children.isSet(octet)) {
                    const new_node = allocator.create(Node(V)) catch unreachable;
                    new_node.* = Node(V).init(allocator);
                    const child = Child(V){ .node = new_node };
                    _ = (&current_node.children).insertAt(octet, child);
                }
                const kid = current_node.children.mustGet(octet);
                switch (kid) {
                    .node => |node| {
                        current_node = node;
                    },
                    else => unreachable,
                }
            }
            std.debug.print("insertAtDepth: end current_node ptr={*}\n", .{current_node});
            // ここでprefixesに格納（prefixのbitsに対応するdepthで）
            var octet_idx: usize = 0;
            if (current_depth == 0 or max_depth == 0) {
                octet_idx = 0;
            } else {
                octet_idx = current_depth - 1;
            }
            const octet_val: u8 = if (current_depth == 0 or max_depth == 0) 0 else (if (octets.len > octet_idx) octets[octet_idx] else 0);
            const idx = base_index.pfxToIdx256(octet_val, last_bits);
            std.debug.print("INSERT: last_bits={}, idx={}, val={} (octet={})\n", .{last_bits, idx, val, octet_val});
            const inserted = current_node.prefixes.insertAt(idx, val);
            std.debug.print("insertAtDepth: final octet_val={}, idx={}, isSet={}, prefixes.len={} (inserted={})\n", .{octet_val, idx, current_node.prefixes.isSet(idx), current_node.prefixes.len(), inserted});
            return inserted;
        }
        
        /// lpmGet gets the longest prefix match for idx
        pub fn lpmGet(self: *const Self, idx: u8) ?struct { base_idx: u8, val: V } {
            const prefixes = self.prefixes;
            if (prefixes.isSet(idx)) {
                return .{ .base_idx = idx, .val = prefixes.mustGet(idx) };
            }
            
            // find the longest prefix match
            var i: u8 = idx;
            while (i > 0) : (i -= 1) {
                if (prefixes.isSet(i)) {
                    return .{ .base_idx = i, .val = prefixes.mustGet(i) };
                }
            }
            
            return null;
        }
        
        /// lpmTest tests if there is a longest prefix match for idx
        pub fn lpmTest(self: *const Self, idx: u8) bool {
            const prefixes = self.prefixes;
            if (prefixes.isSet(idx)) {
                return true;
            }
            
            // find the longest prefix match
            var i: u8 = idx;
            while (i > 0) : (i -= 1) {
                if (prefixes.isSet(i)) {
                    return true;
                }
            }
            
            return false;
        }

        pub fn get(self: *const Self, pfx: *const Prefix) ?V {
            const masked_pfx = pfx.masked();
            const ip = &masked_pfx.addr;
            const bits = masked_pfx.bits;
            const octets = ip.asSlice();
            const max_depth = base_index.maxDepthAndLastBits(bits).max_depth;
            const last_bits = base_index.maxDepthAndLastBits(bits).last_bits;
            std.debug.print("get: bits={}, max_depth={}, last_bits={}, octets={any}\n", .{bits, max_depth, last_bits, octets});
            var current_depth: usize = 0;
            var current_node = self;
            while (current_depth < max_depth) : (current_depth += 1) {
                var octet: u8 = 0;
                if (current_depth < octets.len) {
                    octet = octets[current_depth];
                }
                std.debug.print("get: current_depth={}, octet={}, isSet={}\n", .{current_depth, octet, current_node.children.isSet(octet)});
                if (!current_node.children.isSet(octet)) {
                    break;
                }
                const kid = current_node.children.mustGet(octet);
                switch (kid) {
                    .node => |node| {
                        current_node = node;
                    },
                    else => return null,
                }
            }
            // ループ終了後にprefixesから取得
            var octet: u8 = 0;
            if (current_depth == 0 or max_depth == 0) {
                octet = 0;
            } else if (octets.len > current_depth - 1) {
                octet = octets[current_depth - 1];
            } else {
                octet = 0;
            }
            const idx = base_index.pfxToIdx256(octet, last_bits);
            if (current_node.prefixes.isSet(idx)) {
                const val = current_node.prefixes.get(idx);
                return val;
            }
            
            // prefixesにない場合はchildren側を再帰的に探索
            if (current_node.children.isSet(idx)) {
                if (current_node.children.get(idx)) |child| {
                    switch (child) {
                        .leaf => |leaf| {
                            if (leaf.prefix.eql(pfx.*)) {
                                return leaf.value;
                            }
                        },
                        .fringe => |fringe| {
                            return fringe.value;
                        },
                        .node => |node| {
                            // nodeの場合は再帰的に探索
                            const val = node.get(pfx);
                            if (val) |v| {
                                return v;
                            }
                        },
                    }
                }
            }
            
            return null;
        }

        pub fn lookup(self: *const Self, pfx: *const Prefix) ?V {
            // Go実装準拠: stackでノードを記録し、backtrackしながらLPM探索
            const octets = pfx.addr.asSlice();
            const bits = pfx.bits;
            const max_depth = base_index.maxDepthAndLastBits(bits).max_depth;
            const last_bits = base_index.maxDepthAndLastBits(bits).last_bits;
            var stack: [16]*const Self = undefined;
            var current_node: *const Self = self;
            var depth: u8 = 0;
            while (depth < octets.len) : (depth += 1) {
                const octet = octets[depth];
                stack[depth] = current_node;
                if (depth == max_depth) break;
                if (!current_node.children.isSet(octet)) break;
                const child = current_node.children.mustGet(octet);
                switch (child) {
                    .node => |node| current_node = node,
                    .fringe => |fringe| return fringe.value,
                    .leaf => |leaf| {
                        if (leaf.prefix.containsAddr(pfx.addr)) return leaf.value;
                        break;
                    },
                }
            }
            var d: usize = depth;
            while (true) {
                current_node = stack[d];
                var idx: u8 = 0;
                const octet_val: u8 = if (d < octets.len) @as(u8, octets[d]) else 0;
                if (d == max_depth) {
                    idx = base_index.pfxToIdx256(octet_val, last_bits);
                } else {
                    // Go実装準拠: HostIdx(octet) = octet + 256
                    const host_idx = base_index.hostIdx(octet_val);
                    // host_idxは256-511の範囲なので、u8に収まらない場合は調整
                    if (host_idx > 255) {
                        idx = @as(u8, @intCast(host_idx >> 1));
                    } else {
                        idx = @as(u8, @intCast(host_idx));
                    }
                }
                if (current_node.prefixes.isSet(idx)) {
                    return current_node.prefixes.mustGet(idx);
                }
                if (d == 0) break;
                d -= 1;
            }
            return null;
        }

        pub fn contains(self: *const Self, pfx: *const Prefix) bool {
            const masked_pfx = pfx.masked();
            const ip = &masked_pfx.addr;
            const bits = masked_pfx.bits;
            const octets = ip.asSlice();
            const max_depth = base_index.maxDepthAndLastBits(bits).max_depth;
            const last_bits = base_index.maxDepthAndLastBits(bits).last_bits;
            var current_depth: usize = 0;
            var current_node = self;
            var found = false;
            while (current_depth < max_depth) : (current_depth += 1) {
                const octet_idx: usize = if (current_depth == 0) 0 else current_depth - 1;
                const octet_val: u8 = if (current_depth == 0 or max_depth == 0) 0 else (if (octets.len > octet_idx) octets[octet_idx] else 0);
                const idx = base_index.pfxToIdx256(octet_val, last_bits);
                if (current_node.prefixes.isSet(idx)) {
                    found = true;
                }
                var octet: u8 = 0;
                if (current_depth < octets.len) {
                    octet = octets[current_depth];
                }
                if (!current_node.children.isSet(octet)) {
                    break;
                }
                const kid = current_node.children.mustGet(octet);
                switch (kid) {
                    .node => |node| {
                        current_node = node;
                    },
                    .leaf => |_| {
                        return true;
                    },
                    .fringe => |_| {
                        return true;
                    },
                }
            }
            // 末端もinsertAtDepth/lookupと同じロジック
            var octet: u8 = 0;
            if (current_depth == 0 or max_depth == 0) {
                octet = 0;
            } else if (octets.len > current_depth - 1) {
                octet = octets[current_depth - 1];
            } else {
                octet = 0;
            }
            const idx = base_index.pfxToIdx256(octet, last_bits);
            if (current_node.prefixes.isSet(idx)) {
                found = true;
            }
            return found;
        }

        pub fn update(self: *Self, pfx: *const Prefix, cb: fn (V, bool) V) struct { value: V, was_present: bool } {
            const masked_pfx = pfx.masked();
            const ip = &masked_pfx.addr;
            const bits = masked_pfx.bits;
            const octets = ip.asSlice();
            const max_depth = base_index.maxDepthAndLastBits(bits).max_depth;
            const last_bits = base_index.maxDepthAndLastBits(bits).last_bits;
            var current_depth: usize = 0;
            var current_node = self;
            while (current_depth < max_depth) : (current_depth += 1) {
                var octet: u8 = 0;
                if (current_depth < octets.len) {
                    octet = octets[current_depth];
                }
                // 各depthでprefixesを確認（既存値の更新）
                var octet_idx: usize = 0;
                if (current_depth == 0 or max_depth == 0) {
                    octet_idx = 0;
                } else {
                    octet_idx = current_depth - 1;
                }
                const octet_val: u8 = if (current_depth == 0 or max_depth == 0) 0 else (if (octets.len > octet_idx) octets[octet_idx] else 0);
                const idx = base_index.pfxToIdx256(octet_val, last_bits);
                if (current_node.prefixes.isSet(idx)) {
                    const result = current_node.prefixes.updateAt(idx, cb);
                    return .{ .value = result.new_value, .was_present = result.was_present };
                }
                if (!current_node.children.isSet(octet)) {
                    const new_node = std.heap.page_allocator.create(Node(V)) catch unreachable;
                    new_node.* = Node(V).init(std.heap.page_allocator);
                    const child = Child(V){ .node = new_node };
                    _ = (&current_node.children).insertAt(octet, child);
                }
                const kid = current_node.children.mustGet(octet);
                switch (kid) {
                    .node => |node| {
                        current_node = node;
                    },
                    else => unreachable,
                }
            }
            std.debug.print("update: end current_node ptr={*}\n", .{current_node});
            // ループ終了後にprefixesを更新
            var octet_idx: usize = 0;
            if (current_depth == 0 or max_depth == 0) {
                octet_idx = 0;
            } else {
                octet_idx = current_depth - 1;
            }
            const octet_val: u8 = if (current_depth == 0 or max_depth == 0) 0 else (if (octets.len > octet_idx) octets[octet_idx] else 0);
            const idx = base_index.pfxToIdx256(octet_val, last_bits);
            const result = current_node.prefixes.updateAt(idx, cb);
            return .{ .value = result.new_value, .was_present = result.was_present };
        }

        pub fn delete(self: *Self, pfx: *const Prefix) ?V {
            const masked_pfx = pfx.masked();
            const ip = &masked_pfx.addr;
            const bits = masked_pfx.bits;
            const octets = ip.asSlice();
            const max_depth = base_index.maxDepthAndLastBits(bits).max_depth;
            const last_bits = base_index.maxDepthAndLastBits(bits).last_bits;
            var current_depth: usize = 0;
            var current_node = self;
            while (current_depth < max_depth) : (current_depth += 1) {
                var octet: u8 = 0;
                if (current_depth < octets.len) {
                    octet = octets[current_depth];
                }
                if (!current_node.children.isSet(octet)) {
                    return null;
                }
                const kid = current_node.children.mustGet(octet);
                switch (kid) {
                    .node => |node| {
                        current_node = node;
                    },
                    .leaf => |leaf| {
                        if (leaf.prefix.eql(masked_pfx)) {
                            _ = (&current_node.children).deleteAt(octet);
                            return leaf.value;
                        }
                        return null;
                    },
                    .fringe => |fringe| {
                        if (isFringe(current_depth, bits)) {
                            _ = (&current_node.children).deleteAt(octet);
                            return fringe.value;
                        }
                        return null;
                    },
                }
            }
            // ループ終了後にprefixesから削除
            var octet_idx: usize = 0;
            if (current_depth == 0 or max_depth == 0) {
                octet_idx = 0;
            } else {
                octet_idx = current_depth - 1;
            }
            const octet_val: u8 = if (current_depth == 0 or max_depth == 0) 0 else (if (octets.len > octet_idx) octets[octet_idx] else 0);
            const idx = base_index.pfxToIdx256(octet_val, last_bits);
            if (current_node.prefixes.isSet(idx)) {
                const val = current_node.prefixes.get(idx);
                _ = current_node.prefixes.deleteAt(idx);
                return val;
            }
            return null;
        }
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
        node: *Node(V),
        leaf: LeafNode(V),
        fringe: FringeNode(V),
    };
}

/// isFringe, leaves with /8, /16, ... /128 bits at special positions
/// in the trie.
///
/// Just a path-compressed leaf, inserted at the last
/// possible level as path compressed (depth == maxDepth-1)
/// before inserted just as a prefix in the next level down (depth == maxDepth).
///
/// Nice side effect: A fringe is the default-route for all nodes below this slot!
///
///     e.g. prefix is addr/8, or addr/16, or ... addr/128
///     depth <  maxDepth-1 : a leaf, path-compressed
///     depth == maxDepth-1 : a fringe, path-compressed
///     depth == maxDepth   : a prefix with octet/pfx == 0/0 => idx == 1, a strides default route
pub fn isFringe(depth: usize, bits: u8) bool {
    const max_depth = base_index.maxDepthAndLastBits(bits).max_depth;
    const last_bits = base_index.maxDepthAndLastBits(bits).last_bits;
    return depth == max_depth - 1 and last_bits == 0;
}

/// Prefix represents an IP prefix with address and bit length
pub const Prefix = struct {
    addr: IPAddr,
    bits: u8,
    
    pub fn init(addr: *const IPAddr, bits: u8) Prefix {
        const pfx = Prefix{ .addr = addr.*, .bits = bits };
        std.debug.print("Prefix.init: addr={any}, bits={}\n", .{addr.*, bits});
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
        std.debug.print("Prefix.masked: masked_addr={any}, bits={}\n", .{masked_addr, self.bits});
        return Prefix.init(&masked_addr, self.bits);
    }

    /// 指定アドレスがこのプレフィックスに含まれるか判定
    pub fn containsAddr(self: Prefix, addr: IPAddr) bool {
        // bits長でマスクして比較
        const masked_addr = addr.masked(self.bits);
        return self.addr.eql(masked_addr);
    }
};

/// IPAddr represents an IPv4 or IPv6 address
pub const IPAddr = union(enum) {
    v4: [4]u8,
    v6: [16]u8,
    
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
    
    pub fn asSlice(self: *const IPAddr) []const u8 {
        return switch (self.*) {
            .v4 => |*v4| v4[0..],
            .v6 => |*v6| v6[0..],
        };
    }
    
    pub fn is4(self: IPAddr) bool {
        return switch (self) {
            .v4 => true,
            .v6 => false,
        };
    }
    
    /// masked applies a network mask to the address
    pub fn masked(self: IPAddr, bits: u8) IPAddr {
        switch (self) {
            .v4 => |v4| {
                std.debug.print("IPAddr.masked: v4(before)={any}, bits={}\n", .{v4, bits});
                if (bits == 0) {
                    std.debug.print("IPAddr.masked: v4(bits==0)={any}\n", .{v4});
                    return IPAddr{ .v4 = .{ 0, 0, 0, 0 } };
                }
                if (bits >= 32) {
                    std.debug.print("IPAddr.masked: v4(bits>=32)={any}\n", .{v4});
                    return IPAddr{ .v4 = v4 };
                }
                const mask = @as(u32, 0xffffffff) << @as(u5, @intCast(32 - bits));
                const addr = std.mem.readInt(u32, &v4, .big);
                const masked_addr = addr & mask;
                var result: [4]u8 = undefined;
                std.mem.writeInt(u32, &result, masked_addr, .big);
                std.debug.print("IPAddr.masked: v4(masked)={any}\n", .{result});
                return IPAddr{ .v4 = result };
            },
            .v6 => |v6| {
                std.debug.print("IPAddr.masked: v6(before)={any}, bits={}\n", .{v6, bits});
                if (bits == 0) {
                    std.debug.print("IPAddr.masked: v6(bits==0)={any}\n", .{v6});
                    return IPAddr{ .v6 = .{0} ** 16 };
                }
                if (bits >= 128) {
                    std.debug.print("IPAddr.masked: v6(bits>=128)={any}\n", .{v6});
                    return IPAddr{ .v6 = v6 };
                }
                var result: [16]u8 = v6;
                const full_bytes = bits / 8;
                const remaining_bits = bits % 8;
                if (full_bytes < 16) {
                    @memset(result[full_bytes..], 0);
                }
                if (remaining_bits > 0 and full_bytes < 16) {
                    const mask = @as(u8, 0xff) << @as(u3, @intCast(8 - remaining_bits));
                    result[full_bytes] &= mask;
                }
                std.debug.print("IPAddr.masked: v6(masked)={any}\n", .{result});
                return IPAddr{ .v6 = result };
            },
        }
    }
}; 