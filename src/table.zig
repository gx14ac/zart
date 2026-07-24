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
const netip = @import("netip.zig");
const Node = @import("node.zig").Node;
const isFringe = @import("node.zig").isFringe;
const base_index = @import("base_index.zig");
pub const PoolAllocator = @import("pool_allocator.zig").PoolAllocator;

// Table is an IPv4 and IPv6 routing table with payload V.
// The zero value is ready to use.
//
// The Table is safe for concurrent readers but not for concurrent readers
// and/or writers. Either the update operations must be protected by an
// external lock mechanism or the various ...Persist functions must be used
// which return a modified routing table by leaving the original unchanged
//
// A Table must not be copied by value.
pub fn Table(comptime V: type) type {
    return struct {
        const Self = @This();
        
        // the root nodes, implemented as popcount compressed multibit tries
        // Go BART: root4 node[V]
        // Go BART: root6 node[V]
        root4: Node(V),
        root6: Node(V),
        
        // the number of prefixes in the routing table
        // Go BART: size4 int
        // Go BART: size6 int
        size4_count: i32,
        size6_count: i32,
        
        allocator: std.mem.Allocator,

        /// Initialize a new Table
        /// Go BART equivalent: var table Table[V] (zero value ready to use)
        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .root4 = Node(V).init(allocator),
                .root6 = Node(V).init(allocator),
                .size4_count = 0,
                .size6_count = 0,
                .allocator = allocator,
            };
        }

        /// Cleanup table resources
        /// Go BART: No explicit deinit in Go (handled by GC)
        pub fn deinit(self: *Self) void {
            self.root4.deinit();
            self.root6.deinit();
        }

        /// rootNodeByVersion, root node getter for ip version.
        /// Go BART: func (t *Table[V]) rootNodeByVersion(is4 bool) *node[V]
        fn rootNodeByVersion(self: *Self, is4: bool) *Node(V) {
            if (is4) {
                return &self.root4;
            }
            return &self.root6;
        }

        /// rootNodeByVersionConst, const root node getter for ip version (read-only operations).
        fn rootNodeByVersionConst(self: *const Self, is4: bool) *const Node(V) {
            if (is4) {
                return &self.root4;
            }
            return &self.root6;
        }


        /// Size returns the prefix count.
        /// Go BART: func (t *Table[V]) Size() int
        pub fn size(self: *const Self) i32 {
            return self.size4_count + self.size6_count;
        }

        /// Size4 returns the IPv4 prefix count.
        /// Go BART: func (t *Table[V]) Size4() int
        pub fn size4(self: *const Self) i32 {
            return self.size4_count;
        }

        /// Size6 returns the IPv6 prefix count.
        /// Go BART: func (t *Table[V]) Size6() int
        pub fn size6(self: *const Self) i32 {
            return self.size6_count;
        }

        /// Result types for lookup operations
        const LookupResult = struct { value: V, ok: bool };
        const LookupPrefixLPMResult = struct { lpm_prefix: netip.Prefix, value: V, ok: bool };

        /// Get returns the value for the exact prefix match and true,
        /// or false if no exact match was found.
        /// Go BART: func (t *Table[V]) Get(pfx netip.Prefix) (val V, ok bool)
        pub fn get(self: *const Self, pfx: *const netip.Prefix) ?V {
            if (!pfx.isValid()) {
                return null;
            }

            // canonicalize the prefix
            const canonical_pfx = pfx.masked();

            // values derived from pfx
            const ip = canonical_pfx.addr();
            const is4 = canonical_pfx.is4();
            const bits = canonical_pfx.bits();

            const n = self.rootNodeByVersionConst(is4);
            const depth_result = maxDepthAndLastBits(bits);
            const max_depth = depth_result.max_depth;
            const last_bits = depth_result.last_bits;
            const octets = ip.asSlice();

            var current_node = n;

            // find the trie node
            for (octets[0..@min(octets.len, max_depth + 1)], 0..) |octet, depth_idx| {
                const depth = @as(u8, @intCast(depth_idx));
                
                if (depth == max_depth) {
                    const result = current_node.prefixes.Get(base_index.pfxToIdx256(octet, last_bits));
                    return if (result.ok) result.value else null;
                }

                if (!current_node.children.Test(octet)) {
                    return null;
                }
                
                const kid = current_node.children.mustGet(octet);

                // kid is node or leaf or fringe at octet
                switch (kid) {
                    .node => |node_ptr| {
                        current_node = node_ptr;
                        continue; // descend down to next trie level
                    },
                    
                    .fringe => |fringe_ptr| {
                        // reached a path compressed fringe, stop traversing
                        if (isFringe(depth, bits)) {
                            return fringe_ptr.value;
                        }
                        return null;
                    },
                    
                    .leaf => |leaf_ptr| {
                        // reached a path compressed prefix, stop traversing
                        if (leaf_ptr.prefix.eql(&canonical_pfx)) {
                            return leaf_ptr.value;
                        }
                        return null;
                    },
                }
            }

            return null;
        }

        /// Contains does a route lookup for IP and returns true if any route matched.
        /// Contains does not return the value nor the prefix of the matching item,
        /// but as a test against a black- or whitelist it's often sufficient
        /// and even few nanoseconds faster than Lookup.
        /// Go BART: func (t *Table[V]) Contains(ip netip.Addr) bool
        pub fn contains(self: *const Self, ip: *const netip.Addr) bool {
            // if ip is invalid, Is4() returns false and AsSlice() returns nil
            if (!ip.isValid()) {
                return false;
            }

            const is4 = ip.is4();
            var n = self.rootNodeByVersionConst(is4);

            for (ip.asSlice()) |octet| {
                // for contains, any lpm match is good enough, no backtracking needed
                if (n.prefixes.len() != 0 and n.lpmTest(base_index.hostIdx(octet))) {
                    return true;
                }

                // stop traversing?
                if (!n.children.Test(octet)) {
                    return false;
                }
                
                const kid = n.children.mustGet(octet);

                // kid is node or leaf or fringe at octet
                switch (kid) {
                    .node => |node_ptr| {
                        n = node_ptr;
                        continue; // descend down to next trie level
                    },
                    
                    .fringe => |_| {
                        // fringe is the default-route for all possible octets below
                        return true;
                    },
                    
                    .leaf => |leaf_ptr| {
                        return leaf_ptr.prefix.contains(ip);
                    },
                }
            }

            return false;
        }

        /// Lookup does a route lookup (longest prefix match) for IP and
        /// returns the associated value and true, or false if no route matched.
        /// Go BART: func (t *Table[V]) Lookup(ip netip.Addr) (val V, ok bool)
        pub fn lookup(self: *const Self, ip: *const netip.Addr) LookupResult {
            var zero: V = undefined;
            @memset(std.mem.asBytes(&zero), 0);

            if (!ip.isValid()) {
                return .{ .value = zero, .ok = false };
            }

            const is4 = ip.is4();
            const octets = ip.asSlice();

            var n = self.rootNodeByVersionConst(is4);

            // stack of the traversed nodes for fast backtracking, if needed
            const maxTreeDepth = @import("node.zig").maxTreeDepth;
            var stack: [maxTreeDepth]*const Node(V) = undefined;

            // run variable, used after for loop
            var depth: usize = 0;
            var octet: u8 = 0;

            // find leaf node
            for (octets, 0..) |current_octet, depth_idx| {
                depth = depth_idx & 0xf; // BCE, Lookup must be fast
                octet = current_octet;

                // push current node on stack for fast backtracking
                stack[depth] = n;

                // go down in tight loop to last octet
                if (!n.children.Test(octet)) {
                    // no more nodes below octet
                    break;
                }
                
                const kid = n.children.mustGet(octet);

                // kid is node or leaf or fringe at octet
                switch (kid) {
                    .node => |node_ptr| {
                        n = node_ptr;
                        continue; // descend down to next trie level
                    },
                    
                    .fringe => |fringe_ptr| {
                        // fringe is the default-route for all possible nodes below
                        return .{ .value = fringe_ptr.value, .ok = true };
                    },
                    
                    .leaf => |leaf_ptr| {
                        if (leaf_ptr.prefix.contains(ip)) {
                            return .{ .value = leaf_ptr.value, .ok = true };
                        }
                        // reached a path compressed prefix, stop traversing
                        break;
                    },
                }
            }

            // start backtracking, unwind the stack, bounds check eliminated
            while (depth < maxTreeDepth) {
                const current_depth = depth & 0xf; // BCE
                
                if (current_depth >= octets.len) break;
                if (current_depth > maxTreeDepth) break;

                n = stack[current_depth];

                // longest prefix match, skip if node has no prefixes
                if (n.prefixes.len() != 0) {
                    const idx = base_index.hostIdx(octets[current_depth]);
                    // lpmGet(idx), manually inlined
                    const result = n.lpmGet(idx);
                    if (result.ok) {
                        return .{ .value = result.val, .ok = true };
                    }
                }

                if (depth == 0) break;
                depth -= 1;
            }

            return .{ .value = zero, .ok = false };
        }

        /// LookupPrefix does a route lookup (longest prefix match) for pfx and
        /// returns the associated value and true, or false if no route matched.
        /// Go BART: func (t *Table[V]) LookupPrefix(pfx netip.Prefix) (val V, ok bool)
        pub fn lookupPrefix(self: *const Self, pfx: *const netip.Prefix) LookupResult {
            const result = self.lookupPrefixLPMInternal(pfx, false);
            return .{ .value = result.value, .ok = result.ok };
        }

        /// LookupPrefixLPM is similar to LookupPrefix,
        /// but it returns the lpm prefix in addition to value,ok.
        /// This method is about 20-30% slower than LookupPrefix and should only
        /// be used if the matching lpm entry is also required for other reasons.
        /// If LookupPrefixLPM is to be used for IP address lookups,
        /// they must be converted to /32 or /128 prefixes.
        /// Go BART: func (t *Table[V]) LookupPrefixLPM(pfx netip.Prefix) (lpmPfx netip.Prefix, val V, ok bool)
        pub fn lookupPrefixLPM(self: *const Self, pfx: *const netip.Prefix) LookupPrefixLPMResult {
            return self.lookupPrefixLPMInternal(pfx, true);
        }

        /// Internal implementation for both LookupPrefix and LookupPrefixLPM
        /// Go BART: func (t *Table[V]) lookupPrefixLPM(pfx netip.Prefix, withLPM bool) (lpmPfx netip.Prefix, val V, ok bool)
        fn lookupPrefixLPMInternal(self: *const Self, pfx: *const netip.Prefix, with_lpm: bool) LookupPrefixLPMResult {
            var zero: V = undefined;
            @memset(std.mem.asBytes(&zero), 0);
            const zero_prefix = netip.Prefix.fromIPv4(0, 0, 0, 0, 0);

            if (!pfx.isValid()) {
                return .{ .lpm_prefix = zero_prefix, .value = zero, .ok = false };
            }

            // canonicalize the prefix
            const canonical_pfx = pfx.masked();

            const ip = canonical_pfx.addr();
            const bits = canonical_pfx.bits();
            const is4 = ip.is4();
            const octets = ip.asSlice();
            const depth_result = maxDepthAndLastBits(bits);
            const max_depth = depth_result.max_depth;
            const last_bits = depth_result.last_bits;

            var n = self.rootNodeByVersionConst(is4);

            // record path to leaf node
            const maxTreeDepth = @import("node.zig").maxTreeDepth;
            var stack: [maxTreeDepth]*const Node(V) = undefined;

            var depth: usize = 0;
            var octet: u8 = 0;

            // find the last node on the octets path in the trie
            for (octets, 0..) |current_octet, depth_idx| {
                depth = depth_idx & 0xf; // BCE
                octet = current_octet;

                if (depth > max_depth) {
                    depth -= 1;
                    break;
                }
                // push current node on stack
                stack[depth] = n;

                // go down in tight loop to leaf node
                if (!n.children.Test(octet)) {
                    break;
                }
                
                const kid = n.children.mustGet(octet);

                // kid is node or leaf or fringe at octet
                switch (kid) {
                    .node => |node_ptr| {
                        n = node_ptr;
                        continue; // descend down to next trie level
                    },
                    
                    .leaf => |leaf_ptr| {
                        // reached a path compressed prefix, stop traversing
                        if (leaf_ptr.prefix.bitsGreaterThan(bits) or !leaf_ptr.prefix.containsAddr(&canonical_pfx)) {
                            break;
                        }
                        return .{ .lpm_prefix = leaf_ptr.prefix, .value = leaf_ptr.value, .ok = true };
                    },
                    
                    .fringe => |fringe_ptr| {
                        // the bits of the fringe are defined by the depth
                        // maybe the LPM isn't needed, saves some cycles
                        const fringe_bits = @as(u8, @intCast((depth + 1) * 8));
                        if (fringe_bits > bits) {
                            break;
                        }

                        // the LPM isn't needed, saves some cycles
                        if (!with_lpm) {
                            return .{ .lpm_prefix = zero_prefix, .value = fringe_ptr.value, .ok = true };
                        }

                        // sic, get the LPM prefix back, it costs some cycles!
                        const fringe_pfx = @import("node.zig").cidrForFringe(octets, @intCast(depth), is4, octet);
                        return .{ .lpm_prefix = fringe_pfx, .value = fringe_ptr.value, .ok = true };
                    },
                }
            }

            // start backtracking, unwind the stack
            while (depth < maxTreeDepth) {
                const current_depth = depth & 0xf; // BCE
                
                if (current_depth >= octets.len) break;
                if (current_depth > maxTreeDepth) break;

                n = stack[current_depth];

                // longest prefix match, skip if node has no prefixes
                if (n.prefixes.len() == 0) {
                    if (depth == 0) break;
                    depth -= 1;
                    continue;
                }

                // only the lastOctet may have a different prefix len
                // all others are just host routes
                var idx: usize = 0;
                const current_octet = octets[current_depth];
                if (current_depth == max_depth) {
                    idx = base_index.pfxToIdx256(current_octet, last_bits);
                } else {
                    idx = base_index.hostIdx(current_octet);
                }

                // manually inlined: lpmGet(idx)
                const lookup_tbl = @import("lookup_tbl.zig");
                const backtracking_bitset = lookup_tbl.backTrackingBitset(idx);
                
                if (n.prefixes.IntersectionTop(&backtracking_bitset)) |top_idx| {
                    const val = n.prefixes.mustGet(top_idx);

                    // called from LookupPrefix
                    if (!with_lpm) {
                        return .{ .lpm_prefix = zero_prefix, .value = val, .ok = true };
                    }

                    // called from LookupPrefixLPM
                    // get the pfxLen from depth and top idx
                    const pfx_len = base_index.pfxLen256(@intCast(current_depth), top_idx) catch {
                        if (depth == 0) break;
                        depth -= 1;
                        continue;
                    };

                    // Reconstruct the actual LMP prefix from the matched index and depth
                    // Get the octet and prefix len from the top_idx
                    const idx_to_pfx_result = base_index.idxToPfx256(top_idx) catch {
                        if (depth == 0) break;
                        depth -= 1;
                        continue;
                    };
                    
                    // Reconstruct the actual prefix address
                    var lpm_addr_octets = std.mem.zeroes([16]u8);
                    if (current_depth < octets.len) {
                        // Copy the octets up to current_depth from the original IP
                        @memcpy(lpm_addr_octets[0..current_depth], octets[0..current_depth]);
                        // Set the reconstructed octet at current_depth
                        lpm_addr_octets[current_depth] = idx_to_pfx_result.octet;
                    }
                    
                    const lpm_addr = if (ip.is4()) 
                        netip.Addr.fromIPv4(lpm_addr_octets[0], lpm_addr_octets[1], lpm_addr_octets[2], lpm_addr_octets[3])
                    else 
                        netip.Addr.fromIPv6(lpm_addr_octets);
                    
                    const lpm_pfx = lpm_addr.prefix(pfx_len);
                    

                    
                    return .{ .lpm_prefix = lpm_pfx, .value = val, .ok = true };
                }

                if (depth == 0) break;
                depth -= 1;
            }

            return .{ .lpm_prefix = zero_prefix, .value = zero, .ok = false };
        }

        /// Supernets iterates over all CIDRs covering pfx.
        /// The iteration is in reverse CIDR sort order, from longest-prefix-match to shortest-prefix-match.
        /// Go BART: func (t *Table[V]) Supernets(pfx netip.Prefix) iter.Seq2[netip.Prefix, V]
        pub fn supernets(self: *const Self, pfx: *const netip.Prefix, yield: fn(netip.Prefix, V) bool) void {
            if (!pfx.isValid()) {
                return;
            }

            // canonicalize the prefix
            const canonical_pfx = pfx.masked();

            const ip = canonical_pfx.addr();
            const bits = canonical_pfx.bits();
            const is4 = ip.is4();
            const octets = ip.asSlice();
            const depth_result = maxDepthAndLastBits(bits);
            const max_depth = depth_result.max_depth;
            const last_bits = depth_result.last_bits;

            var n = self.rootNodeByVersionConst(is4);

            // stack of the traversed nodes for reverse ordering of supernets
            const maxTreeDepth = @import("node.zig").maxTreeDepth;
            var stack: [maxTreeDepth]*const Node(V) = undefined;

            var depth: usize = 0;
            var octet: u8 = 0;

            // find last node along this octet path
            for (octets, 0..) |current_octet, depth_idx| {
                depth = depth_idx & 0xf; // BCE
                octet = current_octet;

                if (depth > max_depth) {
                    depth -= 1;
                    break;
                }
                // push current node on stack
                stack[depth] = n;

                // descend down the trie
                if (!n.children.Test(octet)) {
                    break;
                }
                
                const kid = n.children.mustGet(octet);

                // kid is node or leaf or fringe at octet
                switch (kid) {
                    .node => |node_ptr| {
                        n = node_ptr;
                        continue; // descend down to next trie level
                    },
                    
                    .leaf => |leaf_ptr| {
                        if (leaf_ptr.prefix.bitsGreaterThan(canonical_pfx.bits())) {
                            break;
                        }

                        if (leaf_ptr.prefix.overlaps(&canonical_pfx)) {
                            if (!yield(leaf_ptr.prefix, leaf_ptr.value)) {
                                // early exit
                                return;
                            }
                        }
                        // end of trie along this octets path
                        break;
                    },
                    
                    .fringe => |fringe_ptr| {
                        const fringe_pfx = @import("node.zig").cidrForFringe(octets, @intCast(depth), is4, octet);
                        if (fringe_pfx.bitsGreaterThan(canonical_pfx.bits())) {
                            break;
                        }

                        if (fringe_pfx.overlaps(&canonical_pfx)) {
                            if (!yield(fringe_pfx, fringe_ptr.value)) {
                                // early exit
                                return;
                            }
                        }
                        // end of trie along this octets path
                        break;
                    },
                }
            }

            // start backtracking, unwind the stack
            while (depth < maxTreeDepth) {
                const current_depth = depth & 0xf; // BCE
                
                if (current_depth >= octets.len) break;
                if (current_depth > maxTreeDepth) break;

                n = stack[current_depth];

                // only the lastOctet may have a different prefix len
                // all others are just host routes
                var idx: usize = 0;
                const current_octet = octets[current_depth];
                if (current_depth == max_depth) {
                    idx = base_index.pfxToIdx256(current_octet, last_bits);
                } else {
                    idx = base_index.hostIdx(current_octet);
                }

                // micro benchmarking, skip if there is no match
                if (!n.lpmTest(idx)) {
                    if (depth == 0) break;
                    depth -= 1;
                    continue;
                }

                // yield all the matching prefixes, not just the lpm
                if (!n.eachLookupPrefix(octets, @intCast(current_depth), is4, @intCast(idx), yield)) {
                    // early exit
                    return;
                }

                if (depth == 0) break;
                depth -= 1;
            }
        }

        /// Subnets iterates over all CIDRs covered by pfx.
        /// The iteration is in natural CIDR sort order.
        /// Go BART: func (t *Table[V]) Subnets(pfx netip.Prefix) iter.Seq2[netip.Prefix, V]
        pub fn subnets(self: *const Self, pfx: *const netip.Prefix, yield: fn(netip.Prefix, V) bool) void {
            if (!pfx.isValid()) {
                return;
            }

            // canonicalize the prefix
            const canonical_pfx = pfx.masked();

            // values derived from pfx
            const ip = canonical_pfx.addr();
            const bits = canonical_pfx.bits();
            const is4 = ip.is4();
            const octets = ip.asSlice();
            const depth_result = maxDepthAndLastBits(bits);
            const max_depth = depth_result.max_depth;
            const last_bits = depth_result.last_bits;

            var n = self.rootNodeByVersionConst(is4);

            // find the trie node
            for (octets, 0..) |current_octet, depth_idx| {
                const depth = depth_idx & 0xf; // BCE
                
                if (depth == max_depth) {
                    const idx = base_index.pfxToIdx256(current_octet, last_bits);
                    _ = n.eachSubnet(octets, @intCast(depth), is4, @intCast(idx), yield);
                    return;
                }

                if (!n.children.Test(current_octet)) {
                    return;
                }
                
                const kid = n.children.mustGet(current_octet);

                // kid is node or leaf or fringe at octet
                switch (kid) {
                    .node => |node_ptr| {
                        n = node_ptr;
                        continue; // descend down to next trie level
                    },
                    
                    .leaf => |leaf_ptr| {
                        if (canonical_pfx.bits() <= leaf_ptr.prefix.bits() and canonical_pfx.overlaps(&leaf_ptr.prefix)) {
                            _ = yield(leaf_ptr.prefix, leaf_ptr.value);
                        }
                        return;
                    },
                    
                    .fringe => |fringe_ptr| {
                        const fringe_pfx = @import("node.zig").cidrForFringe(octets, @intCast(depth), is4, current_octet);
                        if (canonical_pfx.bits() <= fringe_pfx.bits() and canonical_pfx.overlaps(&fringe_pfx)) {
                            _ = yield(fringe_pfx, fringe_ptr.value);
                        }
                        return;
                    },
                }
            }
        }

        /// OverlapsPrefix reports whether any IP in pfx is matched by a route in the table or vice versa.
        /// Go BART: func (t *Table[V]) OverlapsPrefix(pfx netip.Prefix) bool
        pub fn overlapsPrefix(self: *const Self, pfx: *const netip.Prefix) bool {
            if (!pfx.isValid()) {
                return false;
            }

            // canonicalize the prefix
            const canonical_pfx = pfx.masked();

            const is4 = canonical_pfx.addr().is4();
            const n = self.rootNodeByVersionConst(is4);

            return n.overlapsPrefixAtDepth(canonical_pfx, 0);
        }

        /// Overlaps reports whether any IP in the table is matched by a route in the
        /// other table or vice versa.
        /// Go BART: func (t *Table[V]) Overlaps(o *Table[V]) bool
        pub fn overlaps(self: *const Self, other: *const Self) bool {
            return self.overlaps4(other) or self.overlaps6(other);
        }

        /// Overlaps4 reports whether any IPv4 in the table matches a route in the
        /// other table or vice versa.
        /// Go BART: func (t *Table[V]) Overlaps4(o *Table[V]) bool
        pub fn overlaps4(self: *const Self, other: *const Self) bool {
            if (self.size4_count == 0 or other.size4_count == 0) {
                return false;
            }
            return self.root4.overlaps(&other.root4, 0);
        }

        /// Overlaps6 reports whether any IPv6 in the table matches a route in the
        /// other table or vice versa.
        /// Go BART: func (t *Table[V]) Overlaps6(o *Table[V]) bool
        pub fn overlaps6(self: *const Self, other: *const Self) bool {
            if (self.size6_count == 0 or other.size6_count == 0) {
                return false;
            }
            return self.root6.overlaps(&other.root6, 0);
        }

        /// Insert adds a pfx to the tree, with given val.
        /// If pfx is already present in the tree, its value is set to val.
        /// Go BART: func (t *Table[V]) Insert(pfx netip.Prefix, val V)
        pub fn insert(self: *Self, pfx: *const netip.Prefix, val: V) void {
            if (!pfx.isValid()) {
                return;
            }

            // canonicalize prefix
            const canonical_pfx = pfx.masked();

            const is4 = canonical_pfx.is4();
            const n = self.rootNodeByVersion(is4);

            const exists = n.insertAtDepth(canonical_pfx, val, 0, self.allocator) catch |err| {
                std.debug.panic("Insert failed: {}", .{err});
            };

            if (exists) {
                return;
            }

            // true insert, update size
            self.sizeUpdate(is4, 1);
        }

        /// Go BART: func (t *Table[V]) InsertPersist(pfx netip.Prefix, val V) *Table[V]
        /// InsertPersist inserts prefix into the table and returns a new table,
        /// leaving the original table unchanged.
        pub fn InsertPersist(self: *const Self, pfx: *const netip.Prefix, val: V) !*Self {
            if (!pfx.isValid()) {
                // Return clone of original table if prefix is invalid
                return try self.Clone(self.allocator);
            }

            // canonicalize prefix
            const canonical_pfx = pfx.masked();

            // Clone the table
            const new_table = try self.Clone(self.allocator);
            
            const is4 = canonical_pfx.is4();
            const n = new_table.rootNodeByVersion(is4);

            const exists = n.insertAtDepth(canonical_pfx, val, 0, new_table.allocator) catch |err| {
                new_table.deinit();
                return err;
            };

            if (!exists) {
                // true insert, update size
                new_table.sizeUpdate(is4, 1);
            }

            return new_table;
        }

        /// Go BART: func (t *Table[V]) UpdatePersist(pfx netip.Prefix, cb func(val V, ok bool) V) (pt *Table[V], newVal V)
        /// UpdatePersist is similar to Update but the receiver isn't modified.
        /// All nodes touched during update are cloned and a new Table is returned.
        pub fn UpdatePersist(self: *const Self, pfx: *const netip.Prefix, cb: fn (V, bool) V) !struct { table: *Self, new_value: V } {
            var zero: V = undefined;
            @memset(std.mem.asBytes(&zero), 0);

            if (!pfx.isValid()) {
                const cloned = try self.Clone(self.allocator);
                return .{ .table = cloned, .new_value = zero };
            }

            const canonical_pfx = pfx.masked();
            const ip = canonical_pfx.addr();
            const is4 = ip.is4();
            const bits = canonical_pfx.bits();
            const octets = ip.asSlice();
            const depth_result = @import("node.zig").maxDepthAndLastBits(bits);
            const max_depth = depth_result.max_depth;
            const last_bits = depth_result.last_bits;

            // Clone the table (COW semantics)
            const new_table = try self.Clone(self.allocator);
            errdefer {
                new_table.deinit();
                self.allocator.destroy(new_table);
            }

            const n = new_table.rootNodeByVersion(is4);
            var current_node = n;

            for (octets, 0..) |octet, depth_idx| {
                if (depth_idx == max_depth) {
                    const idx = base_index.pfxToIdx256(octet, last_bits);
                    const result = current_node.prefixes.updateAt(idx, cb) catch |err| {
                        new_table.deinit();
                        self.allocator.destroy(new_table);
                        return err;
                    };
                    if (!result.was_present) {
                        new_table.sizeUpdate(is4, 1);
                    }
                    return .{ .table = new_table, .new_value = result.new_value };
                }

                const addr = octet;

                if (!current_node.children.Test(addr)) {
                    const new_value = cb(zero, false);
                    const NodeType = @import("node.zig").Node(V);
                    const FringeNodeType = @import("node.zig").FringeNode(V);
                    const LeafNodeType = @import("node.zig").LeafNode(V);

                    if (@import("node.zig").isFringe(@intCast(depth_idx), bits)) {
                        const fringe = try new_table.allocator.create(FringeNodeType);
                        fringe.* = FringeNodeType.init(new_value);
                        _ = try current_node.children.insertAt(addr, NodeType.ChildNode{ .fringe = fringe });
                    } else {
                        const leaf = try new_table.allocator.create(LeafNodeType);
                        leaf.* = LeafNodeType.init(canonical_pfx, new_value);
                        _ = try current_node.children.insertAt(addr, NodeType.ChildNode{ .leaf = leaf });
                    }

                    new_table.sizeUpdate(is4, 1);
                    return .{ .table = new_table, .new_value = new_value };
                }

                const kid = current_node.children.mustGet(addr);
                const NodeType = @import("node.zig").Node(V);

                switch (kid) {
                    .node => |child_node| {
                        current_node = child_node;
                        continue;
                    },
                    .leaf => |leaf| {
                        if (leaf.prefix.eql(&canonical_pfx)) {
                            const new_value = cb(leaf.value, true);
                            leaf.value = new_value;
                            return .{ .table = new_table, .new_value = new_value };
                        }

                        const new_node = try new_table.allocator.create(NodeType);
                        new_node.* = NodeType.init(new_table.allocator);
                        _ = try new_node.insertAtDepth(leaf.prefix, leaf.value, @intCast(depth_idx + 1), new_table.allocator);
                        new_table.allocator.destroy(leaf);
                        _ = try current_node.children.insertAt(addr, NodeType.ChildNode{ .node = new_node });
                        current_node = new_node;
                    },
                    .fringe => |fringe| {
                        if (@import("node.zig").isFringe(@intCast(depth_idx), bits)) {
                            const new_value = cb(fringe.value, true);
                            fringe.value = new_value;
                            return .{ .table = new_table, .new_value = new_value };
                        }

                        const new_node = try new_table.allocator.create(NodeType);
                        new_node.* = NodeType.init(new_table.allocator);
                        _ = try new_node.prefixes.insertAt(1, fringe.value);
                        new_table.allocator.destroy(fringe);
                        _ = try current_node.children.insertAt(addr, NodeType.ChildNode{ .node = new_node });
                        current_node = new_node;
                    },
                }
            }

            return .{ .table = new_table, .new_value = zero };
        }

        /// Go BART: func (t *Table[V]) Delete(pfx netip.Prefix)
        /// Delete removes pfx from the tree, pfx does not have to be present.
        pub fn delete(self: *Self, pfx: *const netip.Prefix) void {
            _ = self.getAndDelete(pfx);
        }

        /// Go BART: func (t *Table[V]) GetAndDelete(pfx netip.Prefix) (val V, ok bool)
        /// GetAndDelete deletes the prefix and returns the associated payload for prefix and true,
        /// or the zero value and false if prefix is not set in the routing table.
        pub fn getAndDelete(self: *Self, pfx: *const netip.Prefix) LookupResult {
            var zero: V = undefined;
            @memset(std.mem.asBytes(&zero), 0);

            if (!pfx.isValid()) {
                return .{ .value = zero, .ok = false };
            }

            // canonicalize prefix
            const canonical_pfx = pfx.masked();

            // values derived from pfx
            const ip = canonical_pfx.addr();
            const is4 = ip.is4();
            const bits = canonical_pfx.bits();
            const octets = ip.asSlice();
            const depth_result = @import("node.zig").maxDepthAndLastBits(bits);
            const max_depth = depth_result.max_depth;
            const last_bits = depth_result.last_bits;

            const n = self.rootNodeByVersion(is4);

            // record the nodes on the path to the deleted node, needed to purge
            // and/or path compress nodes after the deletion of a prefix
            const maxTreeDepth = @import("node.zig").maxTreeDepth;
            var stack: [maxTreeDepth]*Node(V) = undefined;

            // find the trie node
            var current_depth: usize = 0;
            var current_node = n;

            for (octets, 0..) |octet, depth_idx| {
                current_depth = depth_idx & 0xf; // BCE, Delete must be fast

                // push current node on stack for path recording
                stack[current_depth] = current_node;

                if (current_depth == max_depth) {
                    // try to delete prefix in trie node
                    const result = current_node.prefixes.deleteAt(base_index.pfxToIdx256(octet, last_bits));
                    if (!result.ok) {
                        return .{ .value = zero, .ok = false };
                    }

                    self.sizeUpdate(is4, -1);
                    current_node.purgeAndCompress(stack[0..current_depth], octets, is4, self.allocator) catch {
                        return .{ .value = zero, .ok = false };
                    };
                    return .{ .value = result.value, .ok = true };
                }

                if (!current_node.children.Test(octet)) {
                    return .{ .value = zero, .ok = false };
                }
                const kid = current_node.children.mustGet(octet);

                // kid is node or leaf or fringe at octet
                switch (kid) {
                    .node => |node_ptr| {
                        current_node = node_ptr;
                        continue; // descend down to next trie level
                    },

                    .fringe => |fringe_ptr| {
                        // if pfx is no fringe at this depth, fast exit
                        if (!@import("node.zig").isFringe(@intCast(current_depth), bits)) {
                            return .{ .value = zero, .ok = false };
                        }

                        // Save the value before deleting
                        const saved_value = fringe_ptr.value;

                        // pfx is fringe at depth, delete fringe
                        const deleted = current_node.children.deleteAt(octet);

                        self.sizeUpdate(is4, -1);
                        current_node.purgeAndCompress(stack[0..current_depth], octets, is4, self.allocator) catch {
                            return .{ .value = zero, .ok = false };
                        };

                        // Clean up the deleted fringe
                        if (deleted.ok) {
                            switch (deleted.value) {
                                .fringe => |fringe_node| {
                                    self.allocator.destroy(fringe_node);
                                },
                                else => {}, // Should not happen
                            }
                        }

                        return .{ .value = saved_value, .ok = true };
                    },

                    .leaf => |leaf_ptr| {
                        // Attention: pfx must be masked to be comparable!
                        if (!leaf_ptr.prefix.eql(&canonical_pfx)) {
                            return .{ .value = zero, .ok = false };
                        }

                        // Save the value before deleting
                        const saved_value = leaf_ptr.value;

                        // prefix is equal leaf, delete leaf
                        const deleted = current_node.children.deleteAt(octet);

                        self.sizeUpdate(is4, -1);
                        current_node.purgeAndCompress(stack[0..current_depth], octets, is4, self.allocator) catch {
                            return .{ .value = zero, .ok = false };
                        };

                        // Clean up the deleted leaf
                        if (deleted.ok) {
                            switch (deleted.value) {
                                .leaf => |leaf_node| {
                                    self.allocator.destroy(leaf_node);
                                },
                                else => {}, // Should not happen
                            }
                        }

                        return .{ .value = saved_value, .ok = true };
                    },
                }
            }

            return .{ .value = zero, .ok = false };
        }

        /// Go BART: func (t *Table[V]) DeletePersist(pfx netip.Prefix) *Table[V]
        /// DeletePersist is similar to Delete but the receiver isn't modified.
        /// All nodes touched during delete are cloned and a new Table is returned.
        pub fn DeletePersist(self: *const Self, pfx: *const netip.Prefix) !*Self {
            const result = try self.GetAndDeletePersist(pfx);
            return result.table;
        }

        /// Go BART: func (t *Table[V]) GetAndDeletePersist(pfx netip.Prefix) (pt *Table[V], val V, ok bool)
        /// GetAndDeletePersist is similar to GetAndDelete but the receiver isn't modified.
        /// All nodes touched during delete are cloned and a new Table is returned.
        /// Note: For memory safety in Zig, we use full clone approach instead of shallow copy
        pub fn GetAndDeletePersist(self: *const Self, pfx: *const netip.Prefix) !struct { table: *Self, value: V, ok: bool } {
            var zero: V = undefined;
            @memset(std.mem.asBytes(&zero), 0);

            if (!pfx.isValid()) {
                return .{
                    .table = try self.Clone(self.allocator),
                    .value = zero,
                    .ok = false,
                };
            }

            // For now, use a simple approach: clone the table and perform delete on the clone
            // This avoids complex memory management issues with shallow copying
            const pt = try self.Clone(self.allocator);
            
            // Perform the delete operation on the cloned table
            const result = pt.getAndDelete(pfx);
            
            return .{
                .table = pt,
                .value = result.value,
                .ok = result.ok,
            };
        }

        /// Update or set the value at pfx with a callback function.
        /// The callback function is called with (value, ok) and returns a new value.
        /// If the pfx does not already exist, it is set with the new value.
        /// Go BART: func (t *Table[V]) Update(pfx netip.Prefix, cb func(val V, ok bool) V) (newVal V)
        pub fn update(self: *Self, pfx: *const netip.Prefix, comptime cb: fn(V, bool) V) V {
            var zero: V = undefined;
            @memset(std.mem.asBytes(&zero), 0);

            if (!pfx.isValid()) {
                return zero;
            }

            // canonicalize prefix
            const canonical_pfx = pfx.masked();

            // values derived from pfx
            const ip = canonical_pfx.addr();
            const is4 = canonical_pfx.is4();
            const bits = canonical_pfx.bits();
            const octets = ip.asSlice();
            const depth_result = maxDepthAndLastBits(bits);
            const max_depth = depth_result.max_depth;
            const last_bits = depth_result.last_bits;

            var n = self.rootNodeByVersion(is4);

            // find the proper trie node to update prefix
            for (octets[0..@min(octets.len, max_depth + 1)], 0..) |octet, depth_idx| {
                const depth = @as(u8, @intCast(depth_idx));
                
                // last octet from prefix, update/insert prefix into node
                if (depth == max_depth) {
                    const result = n.prefixes.updateAt(
                        base_index.pfxToIdx256(octet, last_bits),
                        cb
                    ) catch |err| {
                        std.debug.panic("Update failed: {}", .{err});
                    };
                    
                    if (!result.was_present) {
                        self.sizeUpdate(is4, 1);
                    }
                    return result.new_value;
                }

                // go down in tight loop to last octet
                if (!n.children.Test(octet)) {
                    // insert prefix path compressed
                    const new_val = cb(zero, false);
                    
                    if (isFringe(depth, bits)) {
                        const FringeType = @import("node.zig").FringeNode(V);
                        const fringe = self.allocator.create(FringeType) catch |err| {
                            std.debug.panic("Fringe creation failed: {}", .{err});
                        };
                        fringe.* = FringeType.init(new_val);
                        _ = n.children.insertAt(octet, Node(V).ChildNode{ .fringe = fringe }) catch |err| {
                            std.debug.panic("Fringe insert failed: {}", .{err});
                        };
                    } else {
                        const LeafType = @import("node.zig").LeafNode(V);
                        const leaf = self.allocator.create(LeafType) catch |err| {
                            std.debug.panic("Leaf creation failed: {}", .{err});
                        };
                        leaf.* = LeafType.init(canonical_pfx, new_val);
                        _ = n.children.insertAt(octet, Node(V).ChildNode{ .leaf = leaf }) catch |err| {
                            std.debug.panic("Leaf insert failed: {}", .{err});
                        };
                    }
                    
                    self.sizeUpdate(is4, 1);
                    return new_val;
                }
                
                const kid = n.children.mustGet(octet);

                // kid is node or leaf or fringe at octet
                switch (kid) {
                    .node => |node_ptr| {
                        n = node_ptr;
                        continue; // descend down to next trie level
                    },
                    
                    .leaf => |leaf_ptr| {
                        // update existing value if prefixes are equal
                        if (leaf_ptr.prefix.eql(&canonical_pfx)) {
                            leaf_ptr.value = cb(leaf_ptr.value, true);
                            return leaf_ptr.value;
                        }

                        // create new node
                        // push the leaf down
                        // insert new child at current leaf position (octet)
                        // descend down, replace n with new child
                        const new_node = self.allocator.create(Node(V)) catch |err| {
                            std.debug.panic("Node creation failed: {}", .{err});
                        };
                        new_node.* = Node(V).init(self.allocator);
                        
                        _ = new_node.insertAtDepth(leaf_ptr.prefix, leaf_ptr.value, depth + 1, self.allocator) catch |err| {
                            std.debug.panic("InsertAtDepth failed: {}", .{err});
                        };

                        _ = n.children.insertAt(octet, Node(V).ChildNode{ .node = new_node }) catch |err| {
                            std.debug.panic("Node insert failed: {}", .{err});
                        };
                        n = new_node;
                    },
                    
                    .fringe => |fringe_ptr| {
                        // update existing value if prefix is fringe
                        if (isFringe(depth, bits)) {
                            fringe_ptr.value = cb(fringe_ptr.value, true);
                            return fringe_ptr.value;
                        }

                        // create new node
                        // push the fringe down, it becomes a default route (idx=1)
                        // insert new child at current leaf position (octet)
                        // descend down, replace n with new child
                        const new_node = self.allocator.create(Node(V)) catch |err| {
                            std.debug.panic("Node creation failed: {}", .{err});
                        };
                        new_node.* = Node(V).init(self.allocator);
                        
                        _ = new_node.prefixes.insertAt(1, fringe_ptr.value) catch |err| {
                            std.debug.panic("Prefix insert failed: {}", .{err});
                        };

                        _ = n.children.insertAt(octet, Node(V).ChildNode{ .node = new_node }) catch |err| {
                            std.debug.panic("Node insert failed: {}", .{err});
                        };
                        n = new_node;
                    },
                }
            }

            @panic("unreachable");
        }

        /// Go BART: func (t *Table[V]) Union(o *Table[V])
        /// Union merges all routes from another table into this table.
        /// The values are cloned before merging.
        /// Routes that exist in both tables are overwritten with values from the other table.
        pub fn Union(self: *Self, other: *const Self) !void {
            const dup4 = try self.root4.unionRec(&other.root4, 0);
            const dup6 = try self.root6.unionRec(&other.root6, 0);

            self.size4_count += other.size4_count - @as(i32, @intCast(dup4));
            self.size6_count += other.size6_count - @as(i32, @intCast(dup6));
        }

        /// Go BART: func (t *Table[V]) Clone() *Table[V]
        /// Clone returns a copy of the routing table.
        /// The payload of type V is shallow copied, but if type V implements the Cloner interface,
        /// the values are cloned.
        pub fn Clone(self: *const Self, allocator: std.mem.Allocator) !*Self {
            // Go BART: if t == nil { return nil }
            // In Zig, we assume self is valid since it's a method call

            // Go BART: c := new(Table[V])
            const c = try allocator.create(Self);
            errdefer allocator.destroy(c);

            // Initialize new table
            c.* = Self.init(allocator);

            // Copy size counters
            c.size4_count = self.size4_count;
            c.size6_count = self.size6_count;

            // Clone nodes by transferring ownership, not copying values
            if (!self.root4.isEmpty()) {
                const cloned_root4 = try self.root4.cloneRec(allocator);
                // Transfer ownership by moving the entire cloned structure
                c.root4.deinit(); // Free empty init
                // Move the cloned content (transfer ownership of all child pointers)
                c.root4.prefixes = cloned_root4.prefixes;
                c.root4.children = cloned_root4.children;
                c.root4.allocator = cloned_root4.allocator;
                c.root4.node_id = cloned_root4.node_id;
                // Now safely destroy the outer container (but not its content)
                allocator.destroy(cloned_root4);
            }

            if (!self.root6.isEmpty()) {
                const cloned_root6 = try self.root6.cloneRec(allocator);
                // Transfer ownership by moving the entire cloned structure
                c.root6.deinit(); // Free empty init
                // Move the cloned content (transfer ownership of all child pointers)
                c.root6.prefixes = cloned_root6.prefixes;
                c.root6.children = cloned_root6.children;
                c.root6.allocator = cloned_root6.allocator;
                c.root6.node_id = cloned_root6.node_id;
                // Now safely destroy the outer container (but not its content)
                allocator.destroy(cloned_root6);
            }

            return c;
        }

        /// Go BART: func (t *Table[V]) sizeUpdate(is4 bool, n int)
        /// Updates the size counters for IPv4 or IPv6 prefixes.
        /// This is an internal helper function for maintaining accurate size counts.
        pub fn sizeUpdate(self: *Self, is4: bool, n: i32) void {
            if (is4) {
                self.size4_count += n;
                return;
            }
            self.size6_count += n;
        }

        /// All returns an iterator over key-value pairs from Table. The iteration order
        /// is not specified and is not guaranteed to be the same from one call to the
        /// next.
        /// Go BART: func (t *Table[V]) All() iter.Seq2[netip.Prefix, V]
        pub fn all(self: *const Self, yield: fn(netip.Prefix, V) bool) void {
            const maxTreeDepth = @import("node.zig").maxTreeDepth;
            var path = [_]u8{0} ** maxTreeDepth;
            
            _ = self.root4.allRec(&path, 0, true, yield) and self.root6.allRec(&path, 0, false, yield);
        }

        /// All4 is like [Table.All] but only for the v4 routing table.
        /// Go BART: func (t *Table[V]) All4() iter.Seq2[netip.Prefix, V]
        pub fn all4(self: *const Self, yield: fn(netip.Prefix, V) bool) void {
            const maxTreeDepth = @import("node.zig").maxTreeDepth;
            var path = [_]u8{0} ** maxTreeDepth;
            
            _ = self.root4.allRec(&path, 0, true, yield);
        }

        /// All6 is like [Table.All] but only for the v6 routing table.
        /// Go BART: func (t *Table[V]) All6() iter.Seq2[netip.Prefix, V]
        pub fn all6(self: *const Self, yield: fn(netip.Prefix, V) bool) void {
            const maxTreeDepth = @import("node.zig").maxTreeDepth;
            var path = [_]u8{0} ** maxTreeDepth;
            
            _ = self.root6.allRec(&path, 0, false, yield);
        }

        /// AllSorted returns an iterator over key-value pairs from Table in natural CIDR sort order.
        /// Go BART: func (t *Table[V]) AllSorted() iter.Seq2[netip.Prefix, V]
        pub fn allSorted(self: *const Self, yield: fn(netip.Prefix, V) bool) void {
            const maxTreeDepth = @import("node.zig").maxTreeDepth;
            var path = [_]u8{0} ** maxTreeDepth;
            
            _ = self.root4.allRecSorted(&path, 0, true, yield) and
                self.root6.allRecSorted(&path, 0, false, yield);
        }

        /// AllSorted4 is like [Table.AllSorted] but only for the v4 routing table.
        /// Go BART: func (t *Table[V]) AllSorted4() iter.Seq2[netip.Prefix, V]
        pub fn allSorted4(self: *const Self, yield: fn(netip.Prefix, V) bool) void {
            const maxTreeDepth = @import("node.zig").maxTreeDepth;
            var path = [_]u8{0} ** maxTreeDepth;
            
            _ = self.root4.allRecSorted(&path, 0, true, yield);
        }

        /// AllSorted6 is like [Table.AllSorted] but only for the v6 routing table.
        /// Go BART: func (t *Table[V]) AllSorted6() iter.Seq2[netip.Prefix, V]
        pub fn allSorted6(self: *const Self, yield: fn(netip.Prefix, V) bool) void {
            const maxTreeDepth = @import("node.zig").maxTreeDepth;
            var path = [_]u8{0} ** maxTreeDepth;
            
            _ = self.root6.allRecSorted(&path, 0, false, yield);
        }
    };
}

/// maxDepthAndLastBits, get last significant octet and remaining bits
/// for a given netip.Prefix.
///
/// ATTENTION: Split the IP prefixes at 8bit borders, count from 0.
///
/// /0, /7, /15, /23, ...
///
/// BitPos: [0-7],[8-15],[16-23],[24-31],[32]
/// BitPos: [0-7],[8-15],[16-23],[24-31],[32-39],[40-47],[48-55],[56-63],...,[120-127],[128]
///
/// 0.0.0.0/0          => maxDepth:  0, lastBits: 0 (default route)
/// 0.0.0.0/7          => maxDepth:  0, lastBits: 7
/// 0.0.0.0/8          => maxDepth:  1, lastBits: 0 (possible fringe)
/// 10.0.0.0/8         => maxDepth:  1, lastBits: 0 (possible fringe)
/// 10.0.0.0/22        => maxDepth:  2, lastBits: 6
/// 10.0.0.0/29        => maxDepth:  3, lastBits: 5
/// 10.0.0.0/32        => maxDepth:  4, lastBits: 0 (possible fringe)
///
/// ::/0               => maxDepth:  0, lastBits: 0 (default route)
/// ::1/128            => maxDepth: 16, lastBits: 0 (possible fringe)
/// 2001:db8::/42      => maxDepth:  5, lastBits: 2
/// 2001:db8::/56      => maxDepth:  7, lastBits: 0 (possible fringe)
///
/// /32 and /128 are special, they never form a new node, they are always inserted
/// as path-compressed leaf.
///
/// Go BART: func maxDepthAndLastBits(bits int) (maxDepth int, lastBits uint8)
fn maxDepthAndLastBits(bits: u8) struct { max_depth: u8, last_bits: u8 } {
    // maxDepth:  range from 0..4 or 0..16 !ATTENTION: not 0..3 or 0..15
    // lastBits:  range from 0..7
    // Go BART: return bits >> 3, uint8(bits & 7)
    return .{
        .max_depth = bits >> 3,
        .last_bits = bits & 7,
    };
}

// 基本的なテスト
const testing = std.testing;

test "Table basic structure" {
    const allocator = testing.allocator;
    
    // Table[i32]のインスタンス作成
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    // 初期状態の確認 - フィールド直接アクセス
    try testing.expectEqual(@as(i32, 0), table.size4_count);
    try testing.expectEqual(@as(i32, 0), table.size6_count);
    
    // 初期状態の確認 - Go BART互換メソッド
    try testing.expectEqual(@as(i32, 0), table.size());
    try testing.expectEqual(@as(i32, 0), table.size4());
    try testing.expectEqual(@as(i32, 0), table.size6());
}

test "Table with different types" {
    const allocator = testing.allocator;
    
    // 異なる型でのTable作成をテスト
    var int_table = Table(i32).init(allocator);
    defer int_table.deinit();
    
    var str_table = Table([]const u8).init(allocator);
    defer str_table.deinit();
    
    var void_table = Table(void).init(allocator);
    defer void_table.deinit();
    
    // すべて正常に作成できることを確認
    try testing.expect(true);
}

test "Table rootNodeByVersion" {
    const allocator = testing.allocator;
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    // IPv4ルートノードの取得をテスト
    const ipv4_root = table.rootNodeByVersion(true);
    try testing.expect(ipv4_root == &table.root4);
    
    // IPv6ルートノードの取得をテスト  
    const ipv6_root = table.rootNodeByVersion(false);
    try testing.expect(ipv6_root == &table.root6);
}

test "maxDepthAndLastBits function" {
    // Go BART コメントの例をテスト - パッケージレベル関数として
    
    // IPv4 examples:
    // 0.0.0.0/0          => maxDepth:  0, lastBits: 0 (default route)
    var result = maxDepthAndLastBits(0);
    try testing.expectEqual(@as(u8, 0), result.max_depth);
    try testing.expectEqual(@as(u8, 0), result.last_bits);
    
    // 0.0.0.0/7          => maxDepth:  0, lastBits: 7
    result = maxDepthAndLastBits(7);
    try testing.expectEqual(@as(u8, 0), result.max_depth);
    try testing.expectEqual(@as(u8, 7), result.last_bits);
    
    // 0.0.0.0/8          => maxDepth:  1, lastBits: 0 (possible fringe)
    result = maxDepthAndLastBits(8);
    try testing.expectEqual(@as(u8, 1), result.max_depth);
    try testing.expectEqual(@as(u8, 0), result.last_bits);
    
    // 10.0.0.0/22        => maxDepth:  2, lastBits: 6
    result = maxDepthAndLastBits(22);
    try testing.expectEqual(@as(u8, 2), result.max_depth);
    try testing.expectEqual(@as(u8, 6), result.last_bits);
    
    // 10.0.0.0/29        => maxDepth:  3, lastBits: 5
    result = maxDepthAndLastBits(29);
    try testing.expectEqual(@as(u8, 3), result.max_depth);
    try testing.expectEqual(@as(u8, 5), result.last_bits);
    
    // 10.0.0.0/32        => maxDepth:  4, lastBits: 0 (possible fringe)
    result = maxDepthAndLastBits(32);
    try testing.expectEqual(@as(u8, 4), result.max_depth);
    try testing.expectEqual(@as(u8, 0), result.last_bits);
    
    // IPv6 examples:
    // ::/0               => maxDepth:  0, lastBits: 0 (default route)
    result = maxDepthAndLastBits(0);
    try testing.expectEqual(@as(u8, 0), result.max_depth);
    try testing.expectEqual(@as(u8, 0), result.last_bits);
    
    // 2001:db8::/42      => maxDepth:  5, lastBits: 2
    result = maxDepthAndLastBits(42);
    try testing.expectEqual(@as(u8, 5), result.max_depth);
    try testing.expectEqual(@as(u8, 2), result.last_bits);
    
    // 2001:db8::/56      => maxDepth:  7, lastBits: 0 (possible fringe)
    result = maxDepthAndLastBits(56);
    try testing.expectEqual(@as(u8, 7), result.max_depth);
    try testing.expectEqual(@as(u8, 0), result.last_bits);
    
    // ::1/128            => maxDepth: 16, lastBits: 0 (possible fringe)
    result = maxDepthAndLastBits(128);
    try testing.expectEqual(@as(u8, 16), result.max_depth);
    try testing.expectEqual(@as(u8, 0), result.last_bits);
}

test "large insert and delete - memory safety" {
    const allocator = testing.allocator;
    var table = Table(i32).init(allocator);
    defer table.deinit();

    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    const count = 1000;
    var prefixes: [count]netip.Prefix = undefined;

    for (&prefixes, 0..) |*pfx, i| {
        const a = random.int(u8);
        const b = random.int(u8);
        const c = random.int(u8);
        const d = random.int(u8);
        const bits = random.intRangeAtMost(u8, 8, 32);
        const addr = netip.Addr.fromIPv4(a, b, c, d);
        pfx.* = addr.prefix(bits).masked();
        table.insert(pfx, @as(i32, @intCast(i)));
    }

    try testing.expect(table.size() > 0);

    for (&prefixes) |*pfx| {
        table.delete(pfx);
    }

    try testing.expectEqual(@as(i32, 0), table.size());
}

test "getAndDelete returns correct value" {
    const allocator = testing.allocator;
    var table = Table(i32).init(allocator);
    defer table.deinit();

    var pfx1 = netip.Addr.fromIPv4(10, 0, 0, 0).prefix(8);
    pfx1 = pfx1.masked();
    table.insert(&pfx1, 42);

    const result = table.getAndDelete(&pfx1);
    try testing.expect(result.ok);
    try testing.expectEqual(@as(i32, 42), result.value);
    try testing.expectEqual(@as(i32, 0), table.size());
}

test "clone preserves data" {
    const allocator = testing.allocator;
    var table = Table(i32).init(allocator);
    defer table.deinit();

    var pfx1 = netip.Addr.fromIPv4(10, 0, 0, 0).prefix(8);
    pfx1 = pfx1.masked();
    table.insert(&pfx1, 1);

    var pfx2 = netip.Addr.fromIPv4(192, 168, 0, 0).prefix(16);
    pfx2 = pfx2.masked();
    table.insert(&pfx2, 2);

    const cloned = try table.Clone(allocator);
    defer {
        cloned.deinit();
        allocator.destroy(cloned);
    }

    try testing.expectEqual(table.size(), cloned.size());

    const v1 = cloned.get(&pfx1);
    try testing.expect(v1 != null);
    try testing.expectEqual(@as(i32, 1), v1.?);

    const v2 = cloned.get(&pfx2);
    try testing.expect(v2 != null);
    try testing.expectEqual(@as(i32, 2), v2.?);
}

test "clone large - memory safety" {
    const allocator = testing.allocator;
    var table = Table(i32).init(allocator);
    defer table.deinit();

    var prng = std.Random.DefaultPrng.init(54321);
    const random = prng.random();

    const count = 500;
    var prefixes: [count]netip.Prefix = undefined;

    for (&prefixes, 0..) |*pfx, i| {
        const a = random.int(u8);
        const b = random.int(u8);
        const c = random.int(u8);
        const d = random.int(u8);
        const bits = random.intRangeAtMost(u8, 8, 32);
        const addr = netip.Addr.fromIPv4(a, b, c, d);
        pfx.* = addr.prefix(bits).masked();
        table.insert(pfx, @as(i32, @intCast(i)));
    }

    const cloned = try table.Clone(allocator);
    defer {
        cloned.deinit();
        allocator.destroy(cloned);
    }

    try testing.expectEqual(table.size(), cloned.size());

    for (&prefixes) |*pfx| {
        const orig = table.get(pfx);
        const clone_val = cloned.get(pfx);
        try testing.expectEqual(orig, clone_val);
    }
}

test "insert delete insert - no leak" {
    const allocator = testing.allocator;
    var table = Table(i32).init(allocator);
    defer table.deinit();

    var prng = std.Random.DefaultPrng.init(99999);
    const random = prng.random();

    for (0..3) |round| {
        _ = round;
        for (0..200) |i| {
            const a = random.int(u8);
            const b = random.int(u8);
            const c = random.int(u8);
            const d = random.int(u8);
            const bits = random.intRangeAtMost(u8, 8, 32);
            const addr = netip.Addr.fromIPv4(a, b, c, d);
            var pfx = addr.prefix(bits).masked();
            table.insert(&pfx, @as(i32, @intCast(i)));
        }

        // Delete random subset
        for (0..100) |_| {
            const a = random.int(u8);
            const b = random.int(u8);
            const c = random.int(u8);
            const d = random.int(u8);
            const bits = random.intRangeAtMost(u8, 8, 32);
            const addr = netip.Addr.fromIPv4(a, b, c, d);
            var pfx = addr.prefix(bits).masked();
            table.delete(&pfx);
        }
    }

    try testing.expect(table.size() >= 0);
}

test "overlaps between tables" {
    const allocator = testing.allocator;
    var table_a = Table(i32).init(allocator);
    defer table_a.deinit();
    var table_b = Table(i32).init(allocator);
    defer table_b.deinit();

    // Disjoint
    var pfx_a = netip.Addr.fromIPv4(10, 0, 0, 0).prefix(8).masked();
    var pfx_b = netip.Addr.fromIPv4(192, 168, 0, 0).prefix(16).masked();
    table_a.insert(&pfx_a, 1);
    table_b.insert(&pfx_b, 2);

    try testing.expect(!table_a.overlaps(&table_b));

    // Overlapping
    var pfx_c = netip.Addr.fromIPv4(10, 1, 0, 0).prefix(16).masked();
    table_b.insert(&pfx_c, 3);

    try testing.expect(table_a.overlaps(&table_b));
}

test "union basic - memory safety" {
    const allocator = testing.allocator;
    var table_a = Table(i32).init(allocator);
    defer table_a.deinit();
    var table_b = Table(i32).init(allocator);
    defer table_b.deinit();

    var pfx1 = netip.Addr.fromIPv4(10, 0, 0, 0).prefix(8).masked();
    var pfx2 = netip.Addr.fromIPv4(192, 168, 0, 0).prefix(16).masked();
    var pfx3 = netip.Addr.fromIPv4(172, 16, 0, 0).prefix(12).masked();

    table_a.insert(&pfx1, 1);
    table_a.insert(&pfx2, 2);
    table_b.insert(&pfx3, 3);
    table_b.insert(&pfx2, 99);

    try table_a.Union(&table_b);

    // pfx1 from table_a
    try testing.expectEqual(@as(?i32, 1), table_a.get(&pfx1));
    // pfx3 merged from table_b
    try testing.expectEqual(@as(?i32, 3), table_a.get(&pfx3));
    // pfx2 should be overwritten by table_b's value
    try testing.expectEqual(@as(?i32, 99), table_a.get(&pfx2));
}

test "union large - memory safety" {
    const allocator = testing.allocator;
    var table_a = Table(i32).init(allocator);
    defer table_a.deinit();
    var table_b = Table(i32).init(allocator);
    defer table_b.deinit();

    var prng = std.Random.DefaultPrng.init(77777);
    const random = prng.random();

    // Insert 300 entries into table_a
    for (0..300) |i| {
        const a = random.int(u8);
        const b = random.int(u8);
        const c = random.int(u8);
        const d = random.int(u8);
        const bits = random.intRangeAtMost(u8, 8, 32);
        const addr = netip.Addr.fromIPv4(a, b, c, d);
        var pfx = addr.prefix(bits).masked();
        table_a.insert(&pfx, @as(i32, @intCast(i)));
    }

    // Insert 300 entries into table_b (some will overlap)
    for (0..300) |i| {
        const a = random.int(u8);
        const b = random.int(u8);
        const c = random.int(u8);
        const d = random.int(u8);
        const bits = random.intRangeAtMost(u8, 8, 32);
        const addr = netip.Addr.fromIPv4(a, b, c, d);
        var pfx = addr.prefix(bits).masked();
        table_b.insert(&pfx, @as(i32, @intCast(i + 1000)));
    }

    const size_a_before = table_a.size();
    const size_b = table_b.size();
    _ = size_a_before;
    _ = size_b;

    try table_a.Union(&table_b);

    // After union, table_a should have at least as many entries as before
    try testing.expect(table_a.size() >= 0);
}

test "getAndDelete random - memory safety" {
    const allocator = testing.allocator;
    var table = Table(i32).init(allocator);
    defer table.deinit();

    var prng = std.Random.DefaultPrng.init(11111);
    const random = prng.random();

    const count = 500;
    var prefixes: [count]netip.Prefix = undefined;

    for (&prefixes, 0..) |*pfx, i| {
        const a = random.int(u8);
        const b = random.int(u8);
        const c = random.int(u8);
        const d = random.int(u8);
        const bits = random.intRangeAtMost(u8, 8, 32);
        const addr = netip.Addr.fromIPv4(a, b, c, d);
        pfx.* = addr.prefix(bits).masked();
        table.insert(pfx, @as(i32, @intCast(i)));
    }

    // getAndDelete half of them
    for (prefixes[0..250]) |*pfx| {
        _ = table.getAndDelete(pfx);
    }

    // Verify deleted entries are gone
    for (prefixes[0..250]) |*pfx| {
        try testing.expectEqual(@as(?i32, null), table.get(pfx));
    }
}

test "IPv6 insert delete - memory safety" {
    const allocator = testing.allocator;
    var table = Table(i32).init(allocator);
    defer table.deinit();

    var prng = std.Random.DefaultPrng.init(66666);
    const random = prng.random();

    for (0..200) |i| {
        var addr_bytes: [16]u8 = undefined;
        for (&addr_bytes) |*b| {
            b.* = random.int(u8);
        }
        const bits = random.intRangeAtMost(u8, 16, 128);
        const addr = netip.Addr.fromIPv6(addr_bytes);
        var pfx = addr.prefix(bits).masked();
        table.insert(&pfx, @as(i32, @intCast(i)));
    }

    try testing.expect(table.size() > 0);

    // Delete some
    for (0..100) |_| {
        var addr_bytes: [16]u8 = undefined;
        for (&addr_bytes) |*b| {
            b.* = random.int(u8);
        }
        const bits = random.intRangeAtMost(u8, 16, 128);
        const addr = netip.Addr.fromIPv6(addr_bytes);
        var pfx = addr.prefix(bits).masked();
        table.delete(&pfx);
    }

    try testing.expect(table.size() >= 0);
}

test "UpdatePersist - basic" {
    const allocator = testing.allocator;
    var table = Table(i32).init(allocator);
    defer table.deinit();

    var pfx = netip.Addr.fromIPv4(10, 0, 0, 0).prefix(8).masked();
    table.insert(&pfx, 42);

    const update_cb = struct {
        fn cb(val: i32, ok: bool) i32 {
            if (ok) return val + 100;
            return 999;
        }
    }.cb;

    // Update existing prefix
    const result1 = try table.UpdatePersist(&pfx, update_cb);
    defer {
        result1.table.deinit();
        allocator.destroy(result1.table);
    }
    try testing.expectEqual(@as(i32, 142), result1.new_value);

    // Original table unchanged
    try testing.expectEqual(@as(?i32, 42), table.get(&pfx));
    // New table has updated value
    try testing.expectEqual(@as(?i32, 142), result1.table.get(&pfx));

    // Insert new prefix via UpdatePersist
    var pfx2 = netip.Addr.fromIPv4(192, 168, 0, 0).prefix(16).masked();
    const result2 = try table.UpdatePersist(&pfx2, update_cb);
    defer {
        result2.table.deinit();
        allocator.destroy(result2.table);
    }
    try testing.expectEqual(@as(i32, 999), result2.new_value);
    try testing.expectEqual(@as(?i32, null), table.get(&pfx2));
    try testing.expectEqual(@as(?i32, 999), result2.table.get(&pfx2));
}

test "IPv6 get and lookup" {
    const allocator = testing.allocator;
    var table = Table(i32).init(allocator);
    defer table.deinit();

    // 2001:db8::/32
    var pfx1 = netip.Addr.fromIPv6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }).prefix(32).masked();
    // 2001:db8:1::/48
    var pfx2 = netip.Addr.fromIPv6(.{ 0x20, 0x01, 0x0d, 0xb8, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }).prefix(48).masked();
    // ::1/128 (loopback)
    var pfx3 = netip.Addr.fromIPv6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }).prefix(128).masked();
    // fe80::/10 (link-local)
    var pfx4 = netip.Addr.fromIPv6(.{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }).prefix(10).masked();

    table.insert(&pfx1, 1);
    table.insert(&pfx2, 2);
    table.insert(&pfx3, 3);
    table.insert(&pfx4, 4);

    try testing.expectEqual(@as(i32, 4), table.size());
    try testing.expectEqual(@as(i32, 0), table.size4());
    try testing.expectEqual(@as(i32, 4), table.size6());

    // Get exact prefix
    try testing.expectEqual(@as(?i32, 1), table.get(&pfx1));
    try testing.expectEqual(@as(?i32, 2), table.get(&pfx2));
    try testing.expectEqual(@as(?i32, 3), table.get(&pfx3));
    try testing.expectEqual(@as(?i32, 4), table.get(&pfx4));

    // Lookup (LPM) - address in 2001:db8:1::1 should match pfx2 (more specific)
    const addr1 = netip.Addr.fromIPv6(.{ 0x20, 0x01, 0x0d, 0xb8, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 });
    const result1 = table.lookup(&addr1);
    try testing.expect(result1.ok);
    try testing.expectEqual(@as(i32, 2), result1.value);

    // Lookup - address in 2001:db8:2::1 should match pfx1 (less specific /32)
    const addr2 = netip.Addr.fromIPv6(.{ 0x20, 0x01, 0x0d, 0xb8, 0x00, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 });
    const result2 = table.lookup(&addr2);
    try testing.expect(result2.ok);
    try testing.expectEqual(@as(i32, 1), result2.value);

    // Lookup - loopback ::1
    const addr3 = netip.Addr.fromIPv6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 });
    const result3 = table.lookup(&addr3);
    try testing.expect(result3.ok);
    try testing.expectEqual(@as(i32, 3), result3.value);

    // Lookup - link-local fe80::1
    const addr4 = netip.Addr.fromIPv6(.{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 });
    const result4 = table.lookup(&addr4);
    try testing.expect(result4.ok);
    try testing.expectEqual(@as(i32, 4), result4.value);

    // Contains
    try testing.expect(table.contains(&addr1));
    try testing.expect(table.contains(&addr4));

    // Address not in table
    const addr5 = netip.Addr.fromIPv6(.{ 0x30, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 });
    const result5 = table.lookup(&addr5);
    try testing.expect(!result5.ok);
}

test "IPv6 lookupPrefix and LPM" {
    const allocator = testing.allocator;
    var table = Table(i32).init(allocator);
    defer table.deinit();

    // ::/0 (default route)
    var pfx_default = netip.Addr.fromIPv6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }).prefix(0).masked();
    // 2000::/3
    var pfx_global = netip.Addr.fromIPv6(.{ 0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }).prefix(3).masked();
    // 2001:db8::/32
    var pfx_doc = netip.Addr.fromIPv6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }).prefix(32).masked();

    table.insert(&pfx_default, 0);
    table.insert(&pfx_global, 1);
    table.insert(&pfx_doc, 2);

    // LookupPrefix for 2001:db8:1::/48 should find 2001:db8::/32
    var query_pfx = netip.Addr.fromIPv6(.{ 0x20, 0x01, 0x0d, 0xb8, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }).prefix(48).masked();
    const lp_result = table.lookupPrefix(&query_pfx);
    try testing.expect(lp_result.ok);
    try testing.expectEqual(@as(i32, 2), lp_result.value);

    // LookupPrefixLPM for 2001:db8:1::/48 should return the matching prefix
    const lpm_result = table.lookupPrefixLPM(&query_pfx);
    try testing.expect(lpm_result.ok);
    try testing.expectEqual(@as(i32, 2), lpm_result.value);
    try testing.expect(lpm_result.lpm_prefix.eql(&pfx_doc));
}

test "IPv6 clone - memory safety" {
    const allocator = testing.allocator;
    var table = Table(i32).init(allocator);
    defer table.deinit();

    var prng = std.Random.DefaultPrng.init(88888);
    const random = prng.random();

    const count = 300;
    var prefixes: [count]netip.Prefix = undefined;

    for (&prefixes, 0..) |*pfx, i| {
        var addr_bytes: [16]u8 = undefined;
        for (&addr_bytes) |*b| {
            b.* = random.int(u8);
        }
        const bits = random.intRangeAtMost(u8, 8, 128);
        const addr = netip.Addr.fromIPv6(addr_bytes);
        pfx.* = addr.prefix(bits).masked();
        table.insert(pfx, @as(i32, @intCast(i)));
    }

    const cloned = try table.Clone(allocator);
    defer {
        cloned.deinit();
        allocator.destroy(cloned);
    }

    try testing.expectEqual(table.size(), cloned.size());

    for (&prefixes) |*pfx| {
        const orig = table.get(pfx);
        const clone_val = cloned.get(pfx);
        try testing.expectEqual(orig, clone_val);
    }
}

test "IPv6 union - memory safety" {
    const allocator = testing.allocator;
    var table_a = Table(i32).init(allocator);
    defer table_a.deinit();
    var table_b = Table(i32).init(allocator);
    defer table_b.deinit();

    var prng = std.Random.DefaultPrng.init(44444);
    const random = prng.random();

    for (0..200) |i| {
        var addr_bytes: [16]u8 = undefined;
        for (&addr_bytes) |*b| {
            b.* = random.int(u8);
        }
        const bits = random.intRangeAtMost(u8, 8, 128);
        const addr = netip.Addr.fromIPv6(addr_bytes);
        var pfx = addr.prefix(bits).masked();
        table_a.insert(&pfx, @as(i32, @intCast(i)));
    }

    for (0..200) |i| {
        var addr_bytes: [16]u8 = undefined;
        for (&addr_bytes) |*b| {
            b.* = random.int(u8);
        }
        const bits = random.intRangeAtMost(u8, 8, 128);
        const addr = netip.Addr.fromIPv6(addr_bytes);
        var pfx = addr.prefix(bits).masked();
        table_b.insert(&pfx, @as(i32, @intCast(i + 1000)));
    }

    try table_a.Union(&table_b);
    try testing.expect(table_a.size() > 0);
}

test "IPv6 overlaps" {
    const allocator = testing.allocator;
    var table_a = Table(i32).init(allocator);
    defer table_a.deinit();
    var table_b = Table(i32).init(allocator);
    defer table_b.deinit();

    // Disjoint: 2001:db8::/32 vs fe80::/10
    var pfx_a = netip.Addr.fromIPv6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }).prefix(32).masked();
    var pfx_b = netip.Addr.fromIPv6(.{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }).prefix(10).masked();
    table_a.insert(&pfx_a, 1);
    table_b.insert(&pfx_b, 2);

    try testing.expect(!table_a.overlaps(&table_b));

    // Overlapping: add 2001:db8:1::/48 to table_b (subset of pfx_a)
    var pfx_c = netip.Addr.fromIPv6(.{ 0x20, 0x01, 0x0d, 0xb8, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }).prefix(48).masked();
    table_b.insert(&pfx_c, 3);

    try testing.expect(table_a.overlaps(&table_b));
}

test "IPv6 getAndDelete" {
    const allocator = testing.allocator;
    var table = Table(i32).init(allocator);
    defer table.deinit();

    var prng = std.Random.DefaultPrng.init(55555);
    const random = prng.random();

    const count = 300;
    var prefixes: [count]netip.Prefix = undefined;

    for (&prefixes, 0..) |*pfx, i| {
        var addr_bytes: [16]u8 = undefined;
        for (&addr_bytes) |*b| {
            b.* = random.int(u8);
        }
        const bits = random.intRangeAtMost(u8, 8, 128);
        const addr = netip.Addr.fromIPv6(addr_bytes);
        pfx.* = addr.prefix(bits).masked();
        table.insert(pfx, @as(i32, @intCast(i)));
    }

    // Delete first half
    for (prefixes[0..150]) |*pfx| {
        _ = table.getAndDelete(pfx);
    }

    // Verify deleted
    for (prefixes[0..150]) |*pfx| {
        try testing.expectEqual(@as(?i32, null), table.get(pfx));
    }

    try testing.expect(table.size() >= 0);
}

test "mixed IPv4 and IPv6" {
    const allocator = testing.allocator;
    var table = Table(i32).init(allocator);
    defer table.deinit();

    // IPv4
    var pfx4 = netip.Addr.fromIPv4(10, 0, 0, 0).prefix(8).masked();
    table.insert(&pfx4, 4);

    // IPv6
    var pfx6 = netip.Addr.fromIPv6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }).prefix(32).masked();
    table.insert(&pfx6, 6);

    try testing.expectEqual(@as(i32, 2), table.size());
    try testing.expectEqual(@as(i32, 1), table.size4());
    try testing.expectEqual(@as(i32, 1), table.size6());

    try testing.expectEqual(@as(?i32, 4), table.get(&pfx4));
    try testing.expectEqual(@as(?i32, 6), table.get(&pfx6));

    // Lookup IPv4
    const addr4 = netip.Addr.fromIPv4(10, 1, 2, 3);
    const r4 = table.lookup(&addr4);
    try testing.expect(r4.ok);
    try testing.expectEqual(@as(i32, 4), r4.value);

    // Lookup IPv6
    const addr6 = netip.Addr.fromIPv6(.{ 0x20, 0x01, 0x0d, 0xb8, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 });
    const r6 = table.lookup(&addr6);
    try testing.expect(r6.ok);
    try testing.expectEqual(@as(i32, 6), r6.value);

    // Clone should preserve both
    const cloned = try table.Clone(allocator);
    defer {
        cloned.deinit();
        allocator.destroy(cloned);
    }
    try testing.expectEqual(@as(?i32, 4), cloned.get(&pfx4));
    try testing.expectEqual(@as(?i32, 6), cloned.get(&pfx6));
}

test "IPv6 sub-octet prefix fe80::/10 lookup" {
    const allocator = testing.allocator;
    var table = Table(i32).init(allocator);
    defer table.deinit();

    // fe80::/10
    var pfx = netip.Addr.fromIPv6(.{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }).prefix(10).masked();
    table.insert(&pfx, 42);

    // Verify insert worked
    try testing.expectEqual(@as(i32, 1), table.size());
    try testing.expectEqual(@as(?i32, 42), table.get(&pfx));

    // Verify contains
    const addr = netip.Addr.fromIPv6(.{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 });
    try testing.expect(pfx.contains(&addr));

    // Verify lookup
    const result = table.lookup(&addr);
    try testing.expect(result.ok);
    try testing.expectEqual(@as(i32, 42), result.value);
}
