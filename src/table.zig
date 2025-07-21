// ZART (Zig Adaptive Routing Table) - High-performance IP routing table implementation
//
// ZART is optimized for both memory usage and lookup time
// for longest-prefix match operations.
//
// ZART is a multibit-trie with fixed stride length of 8 bits,
// using an efficient mapping function to map the 256 prefixes
// in each level node to form a complete-binary-tree.
//
// This complete binary tree is implemented with popcount compressed
// sparse arrays together with path compression. This reduces storage
// consumption significantly while maintaining excellent lookup times.
//
// The ZART algorithm is based on bit vectors and precalculated
// lookup tables. The search is performed entirely by fast,
// cache-friendly bitmask operations, utilizing modern CPU bit
// manipulation instruction sets (POPCNT, LZCNT, TZCNT).
//
// The algorithm was specially developed so that it can always work with a fixed
// length of 256 bits. This means that the bitsets fit well in a cache line and
// that loops in hot paths (4x uint64 = 256) can be accelerated by loop unrolling.

const std = @import("std");
const print = std.debug.print;
const node = @import("node.zig");
const art = @import("art_base_index.zig");
const SparseArray256 = @import("sparse_array256.zig").Array256;
const BitSet256 = @import("bitset256.zig").BitSet256;
const lpm_lookup = @import("lpm_lookup_table.zig");

const IPAddr = node.IPAddr;
const Prefix = node.Prefix;

/// ZART Table with Go BART complete compatibility
/// Uses sparse.Array256 exactly like Go BART implementation
pub fn Table(comptime V: type) type {
    return struct {
        const Self = @This();

        // Go BART完全互換のNode実装
        const Node = struct {
            /// prefixes contains the routes, indexed as a complete binary tree with payload V
            /// Go BART: prefixes sparse.Array256[V]
            prefixes: SparseArray256(V),

            /// children, recursively spans the trie with a branching factor of 256.
            /// Go BART: children sparse.Array256[*Node]
            children: SparseArray256(*Node),

            /// allocator for memory management
            allocator: std.mem.Allocator,

            pub fn init(allocator: std.mem.Allocator) !*Node {
                const self = try allocator.create(Node);
                self.* = Node{
                    .prefixes = SparseArray256(V).init(allocator),
                    .children = SparseArray256(*Node).init(allocator),
                    .allocator = allocator,
                };
                return self;
            }

            pub fn deinit(self: *Node) void {
                // Recursively cleanup children (Go BART style)
                var i: u8 = 0;
                while (i < 255) : (i += 1) {
                    if (self.children.testBit(i)) {
                        const child = self.children.mustGet(i);
                        child.deinit();
                    }
                }

                self.prefixes.deinit();
                self.children.deinit();
                self.allocator.destroy(self);
            }

            /// Go BART完全互換 insertPrefix
            pub fn insertPrefix(self: *Node, idx: u8, value: V) !bool {
                const was_existing = try self.prefixes.insertAt(idx, value);
                return !was_existing; // 新規挿入の場合true
            }

            /// Go BART完全互換 getPrefix
            pub fn getPrefix(self: *const Node, idx: u8) ?V {
                return self.prefixes.get(idx);
            }

            /// Go BART完全互換 deletePrefix
            pub fn deletePrefix(self: *Node, idx: u8) bool {
                return self.prefixes.deleteAt(idx) != null;
            }

            /// Go BART完全互換 hasChild
            pub fn hasChild(self: *const Node, octet: u8) bool {
                return self.children.testBit(octet);
            }

            /// Go BART完全互換 getChild
            pub fn getChild(self: *const Node, octet: u8) ?*Node {
                return self.children.get(octet);
            }

            /// Go BART完全互換 setChild
            pub fn setChild(self: *Node, octet: u8, child: *Node) !bool {
                return try self.children.insertAt(octet, child);
            }

            /// Go BART完全互換 lpmGet - backtracking bitset使用
            pub fn lpmGet(self: *const Node, octets: []const u8, depth: usize) ?V {
                if (depth >= octets.len) return null;

                const octet = octets[depth];
                const host_idx = art.hostIdx(octet);

                print("LPM: depth={}, octet={}, host_idx={}\n", .{ depth, octet, host_idx });

                // Use backtracking bitset for LPM (Go BART algorithm)
                const backtracking_bs = lpm_lookup.backTrackingBitset(@as(u16, @intCast(host_idx))).*;

                // Create bitset from prefixes
                var prefixes_bs = BitSet256.init();
                var i: u8 = 1;
                while (i < 255) : (i += 1) {
                    if (self.prefixes.testBit(i)) {
                        prefixes_bs.set(i);
                        print("LPM: Found prefix at idx={}\n", .{i});
                    }
                }

                print("LPM: prefixes_count={}, backtrack_count={}\n", .{ prefixes_bs.popcnt(), backtracking_bs.popcnt() });

                // Find intersection and get highest bit
                const intersection = prefixes_bs.intersection(&backtracking_bs);
                print("LPM: intersection_count={}\n", .{intersection.popcnt()});

                if (intersection.intersectionTop(&intersection)) |bit| {
                    print("LPM: Found highest bit={}\n", .{bit});
                    return self.prefixes.get(bit);
                }

                print("LPM: No intersection found\n", .{});
                return null;
            }
        };

        allocator: std.mem.Allocator,
        root4: ?*Node,
        root6: ?*Node,
        _size4: usize,
        _size6: usize,

        /// Initialize table
        pub fn init(allocator: std.mem.Allocator) !Self {
            return Self{
                .allocator = allocator,
                .root4 = null,
                .root6 = null,
                ._size4 = 0,
                ._size6 = 0,
            };
        }

        /// Deinitialize and free all memory
        pub fn deinit(self: *Self) void {
            if (self.root4) |root| {
                root.deinit();
            }
            if (self.root6) |root| {
                root.deinit();
            }
        }

        /// Get or create root node for IP version
        fn getRootNode(self: *Self, is_ipv4: bool) !*Node {
            if (is_ipv4) {
                if (self.root4 == null) {
                    self.root4 = try Node.init(self.allocator);
                }
                return self.root4.?;
            } else {
                if (self.root6 == null) {
                    self.root6 = try Node.init(self.allocator);
                }
                return self.root6.?;
            }
        }

        /// Insert a prefix with its associated value - Go BART完全互換
        pub fn insert(self: *Self, prefix: Prefix, value: V) !void {
            const root = try self.getRootNode(prefix.addr.isIPv4());

            // Go BART algorithm: traverse to correct depth
            const octets = prefix.addr.octets();
            const max_depth = @min(prefix.bits / 8, octets.len - 1);
            const last_bits = if (prefix.bits % 8 == 0) 8 else @as(u8, @intCast(prefix.bits % 8));

            print("INSERT: octets={any}, max_depth={}, last_bits={}\n", .{ octets, max_depth, last_bits });

            var current_node = root;

            // Traverse to the correct depth (Go BART style)
            for (0..max_depth) |depth| {
                const octet = octets[depth];

                print("INSERT: depth={}, octet={}\n", .{ depth, octet });

                if (!current_node.hasChild(octet)) {
                    const new_node = try Node.init(self.allocator);
                    _ = try current_node.setChild(octet, new_node);
                    print("INSERT: Created new child node at octet={}\n", .{octet});
                }

                current_node = current_node.getChild(octet).?;
            }

            // Insert prefix using ART baseIndex (Go BART style)
            const final_octet = octets[max_depth];
            const idx = art.pfxToIdx256(final_octet, last_bits);

            print("INSERT: final_octet={}, idx={}\n", .{ final_octet, idx });

            const was_new = try current_node.insertPrefix(idx, value);
            print("INSERT: was_new={}, current prefixes_len={}\n", .{ was_new, current_node.prefixes.len() });

            if (was_new) {
                if (prefix.addr.isIPv4()) {
                    self._size4 += 1;
                } else {
                    self._size6 += 1;
                }
            }
        }

        /// Lookup an IP address and return the associated value - Go BART完全互換
        pub fn lookup(self: *const Self, addr: IPAddr) ?V {
            const root = if (addr.isIPv4()) self.root4 else self.root6;
            if (root == null) return null;

            const octets = addr.octets();
            var current_node = root.?;

            // Go BART style backtracking LPM search
            var stack: [16]*Node = undefined;
            var depth: usize = 0;

            // Traverse down the trie
            for (octets, 0..) |octet, d| {
                stack[depth] = current_node;
                depth = d + 1;

                print("LOOKUP: depth={}, octet={}, hasChild={}\n", .{ d, octet, current_node.hasChild(octet) });

                if (!current_node.hasChild(octet)) {
                    break;
                }

                current_node = current_node.getChild(octet).?;
            }

            print("LOOKUP: Starting backtrack from depth={}\n", .{depth});

            // Backtrack and look for longest prefix match (Go BART algorithm)
            while (depth > 0) {
                depth -= 1;
                current_node = stack[depth];

                print("LOOKUP: backtrack depth={}, prefixes_len={}\n", .{ depth, current_node.prefixes.len() });

                if (current_node.prefixes.len() > 0) {
                    if (current_node.lpmGet(octets, depth)) |result| {
                        print("LOOKUP: Found result at depth={}: {}\n", .{ depth, result });
                        return result;
                    }
                }
            }

            print("LOOKUP: No match found\n", .{});
            return null;
        }

        /// Check if an IP address has any matching route - Go BART完全互換
        pub fn contains(self: *const Self, addr: IPAddr) bool {
            return self.lookup(addr) != null;
        }

        /// Get an exact prefix match - Go BART完全互換
        pub fn get(self: *const Self, prefix: Prefix) ?V {
            const root = if (prefix.addr.isIPv4()) self.root4 else self.root6;
            if (root == null) return null;

            const octets = prefix.addr.octets();
            const max_depth = @min(prefix.bits / 8, octets.len - 1);
            const last_bits = if (prefix.bits % 8 == 0) 8 else @as(u8, @intCast(prefix.bits % 8));

            var current_node = root.?;

            // Traverse to the correct depth (Go BART style)
            for (0..max_depth) |depth| {
                const octet = octets[depth];
                if (!current_node.hasChild(octet)) {
                    return null;
                }
                current_node = current_node.getChild(octet).?;
            }

            // Check if the exact prefix exists using ART baseIndex
            const final_octet = octets[max_depth];
            const idx = art.pfxToIdx256(final_octet, last_bits);

            return current_node.getPrefix(idx);
        }

        /// Delete a prefix - Go BART完全互換
        pub fn delete(self: *Self, prefix: Prefix) bool {
            const root = if (prefix.addr.isIPv4()) self.root4 else self.root6;
            if (root == null) return false;

            const octets = prefix.addr.octets();
            const max_depth = @min(prefix.bits / 8, octets.len - 1);
            const last_bits = if (prefix.bits % 8 == 0) 8 else @as(u8, @intCast(prefix.bits % 8));

            var current_node = root.?;

            // Traverse to the correct depth
            for (0..max_depth) |depth| {
                const octet = octets[depth];
                if (!current_node.hasChild(octet)) {
                    return false;
                }
                current_node = current_node.getChild(octet).?;
            }

            // Delete the prefix using ART baseIndex
            const final_octet = octets[max_depth];
            const idx = art.pfxToIdx256(final_octet, last_bits);

            if (current_node.deletePrefix(idx)) {
                if (prefix.addr.isIPv4()) {
                    self._size4 -= 1;
                } else {
                    self._size6 -= 1;
                }
                return true;
            }

            return false;
        }

        /// Get the number of IPv4 routes
        pub fn size4(self: *const Self) usize {
            return self._size4;
        }

        /// Get the number of IPv6 routes
        pub fn size6(self: *const Self) usize {
            return self._size6;
        }

        /// Get the total number of routes
        pub fn size(self: *const Self) usize {
            return self._size4 + self._size6;
        }
    };
}
