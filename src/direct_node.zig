const std = @import("std");
const base_index = @import("base_index.zig");
const bitset256 = @import("bitset256.zig");
const BitSet256 = bitset256.BitSet256;
const node = @import("node.zig");
const Prefix = node.Prefix;
const IPAddr = node.IPAddr;
const LeafNode = node.LeafNode;
const FringeNode = node.FringeNode;
const Child = node.Child;
const LookupResult = node.LookupResult;
const lookup_tbl = @import("lookup_tbl.zig");

inline fn likely(x: bool) bool {
    return x;
}

inline fn unlikely(x: bool) bool {
    return x;
}

/// DirectNode - Go BART compatible sparse array implementation
/// Uses dynamic arrays with popcount compression for Go BART equivalent efficiency
pub fn DirectNode(comptime V: type) type {
    return struct {
        const Self = @This();
        
        // Go BART compatible sparse array structure
        allocator: std.mem.Allocator,
        
        // prefixes: sparse array with popcount compression
        prefixes_bitset: BitSet256,
        prefixes_items: std.ArrayList(V),
        
        // children: sparse array with popcount compression
        children_bitset: BitSet256,
        children_items: std.ArrayList(*Self),
        
        // leaf nodes: sparse array with popcount compression
        leaf_bitset: BitSet256,
        leaf_items: std.ArrayList(LeafNode(V)),
        
        // fringe nodes: sparse array with popcount compression
        fringe_bitset: BitSet256,
        fringe_items: std.ArrayList(FringeNode(V)),
        
        /// Go BART compatible initialization
        pub fn init(allocator: std.mem.Allocator) *Self {
            const self = allocator.create(Self) catch @panic("OOM");
            self.* = Self{
                .allocator = allocator,
                .prefixes_bitset = BitSet256.init(),
                .prefixes_items = std.ArrayList(V).init(allocator),
                .children_bitset = BitSet256.init(),
                .children_items = std.ArrayList(*Self).init(allocator),
                .leaf_bitset = BitSet256.init(),
                .leaf_items = std.ArrayList(LeafNode(V)).init(allocator),
                .fringe_bitset = BitSet256.init(),
                .fringe_items = std.ArrayList(FringeNode(V)).init(allocator),
            };
            return self;
        }
        
        /// Go BART compatible deinit
        pub fn deinit(self: *Self) void {
            // 子ノードを再帰的に解放
            for (self.children_items.items) |child| {
                child.deinit();
            }
            
            self.prefixes_items.deinit();
            self.children_items.deinit();
            self.leaf_items.deinit();
            self.fringe_items.deinit();
            self.allocator.destroy(self);
        }
        
        /// 🚀 Go BART compatible InsertAt implementation - prefixes
        fn insertPrefixAt(self: *Self, idx: u8, value: V) !bool {
            // Go BART: slot exists, overwrite value
            if (self.prefixes_bitset.isSet(idx)) {
                const rank_idx = self.prefixes_bitset.rank(idx) - 1;
                self.prefixes_items.items[rank_idx] = value;
                return true; // exists
            }
            
            // Go BART: new, insert into bitset
            self.prefixes_bitset.set(idx);
            
            // Go BART: insert into dynamic array
            const rank_idx = self.prefixes_bitset.rank(idx) - 1;
            try self.prefixes_items.insert(rank_idx, value);
            
            return false; // new
        }
        
        /// 🚀 Go BART compatible InsertAt implementation - children
        fn insertChildAt(self: *Self, idx: u8, child: *Self) !bool {
            // Go BART: slot exists, overwrite value
            if (self.children_bitset.isSet(idx)) {
                const rank_idx = self.children_bitset.rank(idx) - 1;
                // 既存の子ノードを解放
                self.children_items.items[rank_idx].deinit();
                self.children_items.items[rank_idx] = child;
                return true; // exists
            }
            
            // Go BART: new, insert into bitset
            self.children_bitset.set(idx);
            
            // Go BART: insert into dynamic array
            const rank_idx = self.children_bitset.rank(idx) - 1;
            try self.children_items.insert(rank_idx, child);
            
            return false; // new
        }
        
        /// 🚀 Go BART compatible InsertAt implementation - leaf
        fn insertLeafAt(self: *Self, idx: u8, leaf: LeafNode(V)) !bool {
            // Go BART: slot exists, overwrite value
            if (self.leaf_bitset.isSet(idx)) {
                const rank_idx = self.leaf_bitset.rank(idx) - 1;
                self.leaf_items.items[rank_idx] = leaf;
                return true; // exists
            }
            
            // Go BART: new, insert into bitset
            self.leaf_bitset.set(idx);
            
            // Go BART: insert into dynamic array
            const rank_idx = self.leaf_bitset.rank(idx) - 1;
            try self.leaf_items.insert(rank_idx, leaf);
            
            return false; // new
        }
        
        /// 🚀 Go BART compatible InsertAt implementation - fringe
        fn insertFringeAt(self: *Self, idx: u8, fringe: FringeNode(V)) !bool {
            // Go BART: slot exists, overwrite value
            if (self.fringe_bitset.isSet(idx)) {
                const rank_idx = self.fringe_bitset.rank(idx) - 1;
                self.fringe_items.items[rank_idx] = fringe;
                return true; // exists
            }
            
            // Go BART: new, insert into bitset
            self.fringe_bitset.set(idx);
            
            // Go BART: insert into dynamic array
            const rank_idx = self.fringe_bitset.rank(idx) - 1;
            try self.fringe_items.insert(rank_idx, fringe);
            
            return false; // new
        }
        

        
        /// deinitPersistent - persistent operation safe deallocation (fully corrected version)
        pub fn deinitPersistent(self: *Self) void {
            // safe release of the node tree created by persistent operations
            for (0..self.children_len) |i| {
                self.children_items[i].deinitPersistent();
            }
            self.allocator.destroy(self);
        }
        
        /// isEmpty - check if the node is empty
        pub fn isEmpty(self: *const Self) bool {
            return self.prefixes_items.items.len == 0 and self.children_items.items.len == 0;
        }
        
        /// hasAnyRoutes - check if this node or any of its children has any routes
        pub fn hasAnyRoutes(self: *const Self) bool {
            // Check if this node has any routes
            if (self.prefixes_items.items.len > 0 or self.leaf_items.items.len > 0 or self.fringe_items.items.len > 0) {
                return true;
            }
            
            // Recursively check children
            for (0..256) |i| {
                const octet = @as(u8, @intCast(i));
                if (self.children_bitset.isSet(octet)) {
                    const rank_idx = self.children_bitset.rank(octet) - 1;
                    if (rank_idx < self.children_items.items.len) {
                        if (self.children_items.items[rank_idx].hasAnyRoutes()) {
                            return true;
                        }
                    }
                }
            }
            
            return false;
        }
        
        // =================================================================
        // Phase 4: Persistent Operations (Go BART compatible)
        // =================================================================
        
        /// insertAtDepthPersist - Go BART compatible immutable insert
        pub fn insertAtDepthPersist(self: *const Self, prefix: Prefix, value: V, depth: usize, allocator: std.mem.Allocator) !*Self {
            const new_node = self.clone(allocator);
            _ = try new_node.insertAtDepth(prefix, value, depth);
            return new_node;
        }
        
        /// deleteAtDepthPersist - Go BART compatible immutable delete
        pub fn deleteAtDepthPersist(self: *const Self, prefix: Prefix, _: usize, allocator: std.mem.Allocator) !*Self {
            const new_node = self.clone(allocator);
            _ = new_node.delete(&prefix);
            return new_node;
        }
        
        /// updateAtDepthPersist - Go BART compatible immutable update
        pub fn updateAtDepthPersist(self: *const Self, prefix: Prefix, value: V, depth: usize, allocator: std.mem.Allocator) !*Self {
            const new_node = self.clone(allocator);
            _ = try new_node.insertAtDepth(prefix, value, depth);
            return new_node;
        }
        
        // =================================================================
        // Phase 1: Go BART compatible insert implementation
        // =================================================================
        
        /// Go BART compatible insert implementation - hot path optimized version
        /// Target: 12-15 ns/op (Go BART: 15-20 ns/op)
        pub fn insertAtDepth(self: *Self, prefix: Prefix, value: V, depth: usize) !bool {
            const ip = prefix.addr;
            const bits = prefix.bits;
            const octets = ip.asSlice();
            
            const max_depth_info = base_index.maxDepthAndLastBits(bits);
            const max_depth = max_depth_info.max_depth;
            const last_bits = max_depth_info.last_bits;
            
            // Go BART: find the proper trie node to insert prefix
            // start with prefix octet at depth
            var current_depth = depth;
            var n = self;
            
            while (current_depth < octets.len) : (current_depth += 1) {
                const octet = octets[current_depth];
                
                // Go BART: last masked octet: insert/override prefix/val into node
                if (current_depth == max_depth) {
                    return try n.insertPrefixAt(base_index.pfxToIdx256(octet, last_bits), value);
                }
                
                // Go BART: reached end of trie path ...
                if (!n.children_bitset.isSet(octet)) {
                    // Go BART: insert prefix path compressed as leaf or fringe
                    if (base_index.isFringe(current_depth, bits)) {
                        return try n.insertFringeAt(octet, FringeNode(V).init(value));
                    }
                    return try n.insertLeafAt(octet, LeafNode(V).init(prefix, value));
                }
                
                // Go BART: ... or descend down the trie
                const rank_idx = n.children_bitset.rank(octet) - 1;
                const kid = n.children_items.items[rank_idx];
                
                // Go BART: normal node case is descent continuation
                n = kid;
            }
            
            return false; // unreachable in normal cases
        }
        
        /// 🚀 host route specific high-speed implementation - memory access optimized version
        fn insertHostRouteFast(self: *Self, prefix: Prefix, value: V, depth: usize) bool {
            const octets = prefix.addr.asSlice();
            var n = self;
            var current_depth = depth;
            
            // host route optimization: go directly to last octet
            while (current_depth < octets.len) : (current_depth += 1) {
                const octet = octets[current_depth];
                
                // 🔥 branch prediction optimization: check if last octet (most frequent)
                if (likely(current_depth == octets.len - 1)) {
                    return n.insertLeafDirectOptimized(octet, prefix, value);
                }
                
                // ⚡ memory access optimization: check multiple bitsets at once
                const children_exists = n.children_bitset.isSet(octet);
                const is_pure_child = children_exists and !n.leaf_bitset.isSet(octet) and !n.fringe_bitset.isSet(octet);
                
                // 🔥 branch prediction optimization: check if child node exists (high frequency)
                if (likely(children_exists)) {
                    if (likely(is_pure_child)) {
                        // ⚡ memory access optimization: use precomputed rank
                        const rank_idx = n.fastChildrenRankCached(octet, true) - 1;
                        n = n.children_items[rank_idx];
                        // ⚡ memory access optimization: prefetch for next access
                        @prefetch(&n.children_bitset, .{ .rw = .read, .locality = 3, .cache = .data });
                        continue;
                    }
                    // leaf/fringe expansion is necessary (low frequency)
                    return n.handleChildExpansion(octet, prefix, value, current_depth);
                }
                
                // 🔥 branch prediction optimization: create new intermediate node (low frequency)
                const new_node = Self.init(n.allocator);
                _ = n.insertChildDirect(octet, new_node);
                n = new_node;
            }
            
            return false;
        }
        
        /// 🚀 prefix insertion specific high-speed implementation - memory access optimized version
        fn insertPrefixFast(self: *Self, prefix: Prefix, value: V, depth: usize, max_depth: usize, last_bits: u8) bool {
            const octets = prefix.addr.asSlice();
            var n = self;
            var current_depth = depth;
            
            // prefix optimization: check terminal case before loop
            while (current_depth < octets.len) : (current_depth += 1) {
                const octet = octets[current_depth];
                
                // 🔥 branch prediction optimization 1: terminal case (most frequent)
                if (likely(current_depth == max_depth)) {
                    const idx = base_index.pfxToIdx256(octet, last_bits);
                    return n.insertPrefixDirect(idx, value);
                }
                
                // ⚡ memory access optimization 1: cache state of bitset
                const children_exists = n.children_bitset.isSet(octet);
                const leaf_exists = n.leaf_bitset.isSet(octet);
                const fringe_exists = n.fringe_bitset.isSet(octet);
                
                // 🔥 branch prediction optimization 2: existing child node exists (2nd most frequent)
                if (likely(children_exists)) {
                    if (likely(!leaf_exists and !fringe_exists)) {
                        // ⚡ memory access optimization 2: calculate rank once
                        const rank_idx = n.fastChildrenRankCached(octet, true) - 1;
                        // ⚡ memory access optimization 3: prefetch next node
                        n = n.children_items[rank_idx];
                        @prefetch(&n.children_bitset, .{ .rw = .read, .locality = 3, .cache = .data });
                        continue;
                    }
                    // expansion processing - low frequency
                    return n.handleChildExpansion(octet, prefix, value, current_depth);
                }
                
                // 🔥 branch prediction optimization 3: check if leaf/fringe exists (low frequency)
                if (unlikely(leaf_exists or fringe_exists)) {
                    return n.handleChildExpansion(octet, prefix, value, current_depth);
                }
                
                // 🔥 branch prediction optimization 4: create new path (lowest frequency)
                return n.createNewPath(octet, prefix, value, current_depth, max_depth);
            }
            
            return false;
        }
        
        /// 🚀 high-speed child node type determination
        inline fn isChildNodeFast(self: *const Self, octet: u8) bool {
            // most frequent case: normal node case
            return !self.leaf_bitset.isSet(octet) and !self.fringe_bitset.isSet(octet);
        }
        
        /// 🚀 create new path (cold path only)
        fn createNewPath(self: *Self, octet: u8, prefix: Prefix, value: V, current_depth: usize, max_depth: usize) bool {
            // check if intermediate node creation is necessary
            if (current_depth + 1 < max_depth or (current_depth + 1 == max_depth and current_depth + 1 < prefix.addr.asSlice().len)) {
                const new_node = Self.init(self.allocator);
                _ = self.insertChildDirect(octet, new_node);
                // call recursively without inlining
                return new_node.insertPrefixFast(prefix, value, current_depth + 1, max_depth, base_index.maxDepthAndLastBits(prefix.bits).last_bits);
            }
            
            // insert at leaf/fringe at final depth
            if (base_index.isFringe(current_depth, prefix.bits)) {
                return self.insertFringeDirectOptimized(octet, prefix, value);
            }
            return self.insertLeafDirectOptimized(octet, prefix, value);
        }
        
        /// Go BART optimized: child node type determination (old version - backward compatibility)
        inline fn isChildNode(self: *const Self, octet: u8) bool {
            // check if it's a normal node (most frequent case)
            return !self.leaf_bitset.isSet(octet) and !self.fringe_bitset.isSet(octet);
        }
        
        // Phase 5: BitSet256 rank operation optimization - high speed
        
        /// fast rank calculation - children_bitset specific optimization
        inline fn fastChildrenRank(self: *const Self, idx: u8) u16 {
            // most frequent case: fast path for single set bit
            if (self.children_items.items.len == 1) {
                // if result is known for single element, skip calculation
                return if (self.children_bitset.isSet(idx)) 1 else 0;
            }
            
            // general case: standard rank calculation
            return self.children_bitset.rank(idx);
        }
        
        /// fast rank calculation - prefixes_bitset specific optimization
        inline fn fastPrefixesRank(self: *const Self, idx: u8) u16 {
            // most frequent case: fast path for single set bit
            if (self.prefixes_items.items.len == 1) {
                // if result is known for single element, skip calculation
                return if (self.prefixes_bitset.isSet(idx)) 1 else 0;
            }
            
            // general case: standard rank calculation
            return self.prefixes_bitset.rank(idx);
        }
        
        /// fast rank calculation - leaf_bitset specific optimization
        inline fn fastLeafRank(self: *const Self, idx: u8) u16 {
            // most frequent case: fast path for single set bit
            if (self.leaf_items.items.len == 1) {
                // if result is known for single element, skip calculation
                return if (self.leaf_bitset.isSet(idx)) 1 else 0;
            }
            
            // general case: standard rank calculation
            return self.leaf_bitset.rank(idx);
        }
        
        /// fast rank calculation - fringe_bitset specific optimization
        inline fn fastFringeRank(self: *const Self, idx: u8) u16 {
            // most frequent case: fast path for single set bit
            if (self.fringe_items.items.len == 1) {
                // if result is known for single element, skip calculation
                return if (self.fringe_bitset.isSet(idx)) 1 else 0;
            }
            
            // general case: standard rank calculation
            return self.fringe_bitset.rank(idx);
        }
        
        /// Go BART optimized: child node expansion processing (exceptional case)
        fn handleChildExpansion(self: *Self, octet: u8, prefix: Prefix, value: V, depth: usize) bool {
            // Go BART: kid is node or leaf at addr
            
            // leaf case
            if (self.leaf_bitset.isSet(octet)) {
                const leaf_rank = self.fastLeafRank(octet) - 1;
                const leaf = self.leaf_items.items[leaf_rank];
                
                // Go BART: reached a path compressed prefix
                // override value in slot if prefixes are equal
                if (leaf.prefix.eql(prefix)) {
                    self.leaf_items[leaf_rank] = LeafNode(V).init(prefix, value);
                    return true; // exists
                }
                
                // Go BART: create new node, push the leaf down
                const new_node = Self.init(self.allocator);
                
                // First insert the leaf - if this fails, we can safely cleanup
                _ = new_node.insertAtDepth(leaf.prefix, leaf.value, depth + 1) catch {
                    // Failed to insert leaf - cleanup and return false
                    new_node.deinit();
                    return false;
                };
                
                // Convert the node structure first
                // 1. remove from leaf_bitset
                self.leaf_bitset.clear(octet);
                
                // 2. remove from leaf_items (shift array)
                self.removeLeafItem(leaf_rank);
                self.leaf_items.items.len -= 1;
                
                // 3. insert new node into children_items
                self.children_bitset.set(octet);
                const children_rank_idx = self.children_bitset.rank(octet) - 1;
                self.insertChildItem(children_rank_idx, new_node) catch unreachable;
                self.children_items.items.len += 1;
                
                // Go BART: descend down, replace n with new child
                // Now insert the new prefix by recursing with the new node
                return new_node.insertAtDepth(prefix, value, depth + 1) catch false;
            }
            
            // fringe case
            if (self.fringe_bitset.isSet(octet)) {
                const fringe_rank = self.fastFringeRank(octet) - 1;
                const fringe = self.fringe_items.items[fringe_rank];
                
                // Go BART: reached a path compressed fringe
                // override value in slot if pfx is a fringe
                if (base_index.isFringe(depth, prefix.bits)) {
                    self.fringe_items[fringe_rank] = FringeNode(V).init(value);
                    return true; // exists
                }
                
                // Go BART: create new node, push the fringe down
                const new_node = Self.init(self.allocator);
                
                // First insert the fringe as default route (idx=1)
                _ = new_node.insertPrefixDirect(1, fringe.value);
                
                // Convert the node structure first
                // 1. remove from fringe_bitset
                self.fringe_bitset.clear(octet);
                
                // 2. remove from fringe_items (shift array)
                self.removeFringeItem(fringe_rank);
                self.fringe_items.items.len -= 1;
                
                // 3. insert new node into children_items
                self.children_bitset.set(octet);
                const children_rank_idx = self.children_bitset.rank(octet) - 1;
                self.insertChildItem(children_rank_idx, new_node) catch unreachable;
                self.children_items.items.len += 1;
                
                // Go BART: descend down, replace n with new child
                // Now insert the new prefix by recursing with the new node
                return new_node.insertAtDepth(prefix, value, depth + 1) catch false;
            }
            
            return false; // should not reach here
        }
        
        /// Phase 2 optimization: Direct indexing prefix insertion (Go BART sparse.Array256 transplantation)
        fn insertPrefixDirect(self: *Self, idx: u8, value: V) bool {
            // ⚡ memory access optimization: check state of bitset once
            const was_present = self.prefixes_bitset.isSet(idx);
            
            // 🔥 branch prediction optimization: new insertion is most frequent (more than overwrite)
            if (likely(!was_present)) {
                // Go BART: calculate rank BEFORE bitset update
                const rank_idx = self.prefixes_bitset.rank(idx);
                
                // Go BART: new, insert into bitset
                self.prefixes_bitset.set(idx);
                
                // ⚡ memory access optimization: prefetch array access
                @prefetch(&self.prefixes_items[rank_idx], .{ .rw = .write, .locality = 3, .cache = .data });
                
                // Go BART: efficient single insertItem operation
                self.insertPrefixItem(rank_idx, value);
                self.prefixes_items.items.len += 1;
                
                return false; // new insertion
            } else {
                // Go BART: slot exists, overwrite value (no shifting needed)
                // ⚡ memory access optimization: cached rank calculation
                const rank_idx = self.fastPrefixesRankCached(idx, true) - 1;
                self.prefixes_items.items[rank_idx] = value;
                return true; // existing overwrite
            }
        }
        
        /// Go BART sparse.Array256 insertItem transplantation - memory access optimized version
        fn insertPrefixItem(self: *Self, index: usize, item: V) void {
            // Phase 5: array shift optimization - duplicate memory handling
            if (self.prefixes_items.items.len > index) {
                // move memory area from back to front
                const move_count = self.prefixes_items.items.len - index;
                
                // ⚡ memory access optimization: prefetch destination memory
                @prefetch(&self.prefixes_items[index + move_count], .{ .rw = .write, .locality = 3, .cache = .data });
                
                // move elements from back to front
                if (move_count <= 8) {
                    // small size is expanded loop from back to front
                    var i: usize = move_count;
                    while (i > 0) {
                        i -= 1;
                        self.prefixes_items.items[index + 1 + i] = self.prefixes_items.items[index + i];
                    }
                } else {
                    // large size uses std.mem.copyBackwards
                    std.mem.copyBackwards(V, self.prefixes_items[index + 1..index + 1 + move_count], self.prefixes_items[index..index + move_count]);
                }
            }
            
            self.prefixes_items.items[index] = item;
        }
        
        /// Phase 3 optimization: Go BART compatible high-speed Fringe insertion
        fn insertFringeDirectOptimized(self: *Self, octet: u8, prefix: Prefix, value: V) bool {
            _ = prefix; // FringeNode does not use prefix
            const was_present = self.fringe_bitset.isSet(octet);
            
            if (was_present) {
                // Go BART: overwrite existing (no shifting needed)
                const rank_idx = self.fringe_bitset.rank(octet) - 1;
                self.fringe_items.items[rank_idx] = FringeNode(V).init(value);
                return true;
            }
            
            // Go BART: new insertion
            // 1. Calculate rank BEFORE bitset update
            const rank_idx = self.fringe_bitset.rank(octet);
            
            // 2. Update fringe bitset (fringe node does not set children_bitset)
            self.fringe_bitset.set(octet);
            const new_fringe = FringeNode(V).init(value);
            self.insertFringeItem(rank_idx, new_fringe);
            self.fringe_items.items.len += 1;
            
            return false;
        }
        
        /// Go BART fringe insertItem optimization - optimized version
        fn insertFringeItem(self: *Self, index: usize, item: FringeNode(V)) void {
            // Phase 5: array shift optimization - memmove usage
            if (self.fringe_items.items.len > index) {
                const src = &self.fringe_items.items[index];
                const dst = &self.fringe_items.items[index + 1];
                const move_count = self.fringe_items.items.len - index;
                
                // small size uses Unrolled loop, large size uses memmove
                if (move_count <= 8) {
                    // Unrolled loop optimization
                    comptime var i: usize = 0;
                    inline while (i < 8) : (i += 1) {
                        if (i < move_count) {
                            @as([*]FringeNode(V), @ptrCast(dst))[i] = @as([*]FringeNode(V), @ptrCast(src))[i];
                        }
                    }
                } else {
                    std.mem.copyBackwards(FringeNode(V), @as([*]FringeNode(V), @ptrCast(dst))[0..move_count], @as([*]FringeNode(V), @ptrCast(src))[0..move_count]);
                }
            }
            
            self.fringe_items.items[index] = item;
        }
        
        /// Phase 3 optimization: Go BART compatible high-speed Leaf insertion - memory access optimized version
        fn insertLeafDirectOptimized(self: *Self, octet: u8, prefix: Prefix, value: V) bool {
            // ⚡ memory access optimization: check state of bitset once
            const was_present = self.leaf_bitset.isSet(octet);
            
            if (was_present) {
                // Go BART: overwrite existing (no shifting needed)
                // ⚡ memory access optimization: cached rank calculation
                const rank_idx = self.fastLeafRankCached(octet, true) - 1;
                self.leaf_items.items[rank_idx] = LeafNode(V).init(prefix, value);
                return true;
            }
            
            // Go BART: new insertion
            // 1. Calculate rank BEFORE bitset update
            const rank_idx = self.leaf_bitset.rank(octet);
            
            // 2. Update leaf bitset (leaf node does not set children_bitset)
            self.leaf_bitset.set(octet);
            
            // ⚡ memory access optimization: prefetch array access
            @prefetch(&self.leaf_items[rank_idx], .{ .rw = .write, .locality = 3, .cache = .data });
            
            // 3. Efficient single insertItem operation
            const new_leaf = LeafNode(V).init(prefix, value);
            self.insertLeafItem(rank_idx, new_leaf);
            self.leaf_items.items.len += 1;
            
            return false;
        }
        
        /// Go BART sparse.Array256 leaf insertItem optimization - optimized version
        fn insertLeafItem(self: *Self, index: usize, item: LeafNode(V)) void {
            // Phase 5: array shift optimization - memmove usage
            if (self.leaf_items.items.len > index) {
                const src = &self.leaf_items.items[index];
                const dst = &self.leaf_items.items[index + 1];
                const move_count = self.leaf_items.items.len - index;
                
                // small size uses Unrolled loop, large size uses memmove
                if (move_count <= 8) {
                    // Unrolled loop optimization
                    comptime var i: usize = 0;
                    inline while (i < 8) : (i += 1) {
                        if (i < move_count) {
                            @as([*]LeafNode(V), @ptrCast(dst))[i] = @as([*]LeafNode(V), @ptrCast(src))[i];
                        }
                    }
                } else {
                    std.mem.copyBackwards(LeafNode(V), @as([*]LeafNode(V), @ptrCast(dst))[0..move_count], @as([*]LeafNode(V), @ptrCast(src))[0..move_count]);
                }
            }
            
            self.leaf_items.items[index] = item;
        }
        
        /// Remove leaf item at index (updated for ArrayList)
        fn removeLeafItem(self: *Self, index: usize) void {
            if (index >= self.leaf_items.items.len) return;
            
            const move_count = self.leaf_items.items.len - index - 1;
            
            if (move_count > 0) {
                if (move_count <= 4) {
                    // small size is manual loop
                    var i: usize = 0;
                    while (i < move_count) : (i += 1) {
                        self.leaf_items.items[index + i] = self.leaf_items.items[index + i + 1];
                    }
                } else {
                    // large size uses std.mem.copyForwards
                    std.mem.copyForwards(LeafNode(V), self.leaf_items.items[index..index + move_count], self.leaf_items.items[index + 1..index + 1 + move_count]);
                }
            }
            
            // clear last element for debugging
            if (self.leaf_items.items.len > 0) {
                self.leaf_items.items[self.leaf_items.items.len - 1] = undefined;
            }
        }
        
        /// Remove fringe item at index (updated for ArrayList)
        fn removeFringeItem(self: *Self, index: usize) void {
            if (index >= self.fringe_items.items.len) return;
            
            const move_count = self.fringe_items.items.len - index - 1;
            
            if (move_count > 0) {
                if (move_count <= 4) {
                    // small size is manual loop
                    var i: usize = 0;
                    while (i < move_count) : (i += 1) {
                        self.fringe_items.items[index + i] = self.fringe_items.items[index + i + 1];
                    }
                } else {
                    // large size uses std.mem.copyForwards
                    std.mem.copyForwards(FringeNode(V), self.fringe_items.items[index..index + move_count], self.fringe_items.items[index + 1..index + 1 + move_count]);
                }
            }
            
            // clear last element for debugging
            if (self.fringe_items.items.len > 0) {
                self.fringe_items.items[self.fringe_items.items.len - 1] = undefined;
            }
        }
        
        /// Go BART compatible high-speed child node insertion (memory safe version)
        fn insertChildDirect(self: *Self, octet: u8, child: *Self) bool {
            const was_present = self.children_bitset.isSet(octet);
            
            if (was_present) {
                // Go BART: overwrite existing (no shifting needed)
                const rank_idx = self.children_bitset.rank(octet) - 1;
                
                // 🚨 important: only release if new child is different from existing child
                if (self.children_items.items[rank_idx] != child) {
                    self.children_items.items[rank_idx].deinit();
                }
                self.children_items.items[rank_idx] = child;
                return true;
            }
            
            // Go BART: new insertion
            // 1. Calculate rank BEFORE bitset update
            const rank_idx = self.children_bitset.rank(octet);
            
            // 2. Update children bitset
            self.children_bitset.set(octet);
            
            // 3. Insert child item (error handling included)
            self.insertChildItem(rank_idx, child) catch {
                // safe rollback on insertion failure
                self.children_bitset.clear(octet);
                return false;
            };
            self.children_items.items.len += 1;
            
            // 4. Integrity check (for debugging)
            if (self.children_items.items.len != @as(u16, self.children_bitset.popcnt())) {
                // handle error case
                self.children_bitset.clear(octet);
                self.children_items.items.len -= 1;
                // rollback insertion (but do not release child nodes)
                return false;
            }
            
            return false;
        }
        
        /// Children insertItem optimization - memory safe version
        fn insertChildItem(self: *Self, index: usize, item: *Self) !void {
            // boundary check
            if (index > self.children_items.items.len or self.children_items.items.len >= 256) {
                return error.IndexOutOfBounds;
            }
            
            // Phase 5: array shift optimization - memmove usage
            if (self.children_items.items.len > index) {
                const src = &self.children_items.items[index];
                const dst = &self.children_items.items[index + 1];
                const move_count = self.children_items.items.len - index;
                
                // small size uses Unrolled loop, large size uses memmove
                if (move_count <= 8) {
                    // Unrolled loop optimization
                    comptime var i: usize = 0;
                    inline while (i < 8) : (i += 1) {
                        if (i < move_count) {
                            @as([*]*Self, @ptrCast(dst))[i] = @as([*]*Self, @ptrCast(src))[i];
                        }
                    }
                } else {
                    std.mem.copyBackwards(*Self, @as([*]*Self, @ptrCast(dst))[0..move_count], @as([*]*Self, @ptrCast(src))[0..move_count]);
                }
            }
            
            self.children_items.items[index] = item;
        }
        
        // =================================================================
        // Phase 2,3: additional implementation - Fringe/Leaf Nodes matches method
        // =================================================================
        
        /// FringeNode matches method implementation
        fn FringeMatches(comptime Value: type) type {
            return struct {
                pub fn matches(self: *const FringeNode(Value), addr: *const IPAddr, depth: usize) bool {
                    // FringeNode does not have a prefix, so match based on position
                    // Implementation based on actual Go BART algorithm
                    _ = self; // FringeNode only holds value
                    _ = addr;
                    _ = depth;
                    // Fringe is always treated as a match at current depth
                    return true;
                }
            };
        }
        
        /// LeafNode matches method implementation
        fn LeafMatches(comptime Value: type) type {
            return struct {
                pub fn matches(self: *const LeafNode(Value), addr: *const IPAddr) bool {
                    // Check if LeafNode's prefix contains addr
                    return self.prefix.containsAddr(addr.*);
                }
            };
        }

        // =================================================================
        // Phase 2: LPM Backtracking implementation
        // =================================================================
        
        /// Phase 2 optimization: high-speed LPM backtracking (corrected version)
        pub fn lmpGetOptimized(self: *const Self, idx: u8) struct { base_idx: u8, val: V, ok: bool } {
            // Always use dynamic backTrackingBitset for debugging
            var bs: BitSet256 = lookup_tbl.backTrackingBitset(idx);
            if (self.prefixes_bitset.intersectionTop(&bs)) |top| {
                const rank_idx = self.prefixes_bitset.rank(top) - 1;
                return .{ 
                    .base_idx = top, 
                    .val = self.prefixes_items.items[rank_idx], 
                    .ok = true 
                };
            }
            
            return .{ .base_idx = 0, .val = undefined, .ok = false };
        }
        
        /// lpmTest - check if LPM exists
        pub fn lpmTest(self: *const Self, idx: usize) bool {
            if (idx < lookup_tbl.lookupTbl.len) {
                const bs = lookup_tbl.lookupTbl[idx];
                return self.prefixes_bitset.intersectsAny(&bs);
            }
            
            var bs: BitSet256 = lookup_tbl.backTrackingBitset(idx);
            return self.prefixes_bitset.intersectsAny(&bs);
        }
        
        // =================================================================
        // Phase 2 & 4: high-speed lookup implementation (including IPv6 optimization)
        // =================================================================
        
        /// Phase 5 optimization: Go BART compatible high-speed lookup implementation - branch prediction optimization version
        /// Target: 3-5 ns/op (Go BART: 17.50 ns/op) 
        pub fn lookupOptimized(self: *const Self, addr: *const IPAddr) node.LookupResult(V) {
            const octets = addr.asSlice();
            var n = self;
            
            // Go BART: stack of the traversed nodes for fast backtracking
            var stack: [16]*const Self = undefined;
            
            // Go BART variables
            var depth: usize = 0;
            var octet: u8 = 0;
            
            // Go BART: find leaf node (forward traversal) - branch prediction optimization
            for (octets, 0..) |current_octet, d| {
                depth = d & 0xf; // Go BART: BCE, Lookup must be fast
                octet = current_octet;
                
                // Go BART: push current node on stack for fast backtracking
                stack[depth] = n;
                
                // Go BART: go down in tight loop to last octet
                // HOT PATH: usually child node exists (branch prediction optimization)
                // Correction: also check leaf node and fringe node
                if (!n.children_bitset.isSet(octet) and !n.leaf_bitset.isSet(octet) and !n.fringe_bitset.isSet(octet)) {
                    // no more nodes below octet
                    break;
                }
                
                // Go BART: fringeNode case - low frequency (branch prediction optimization)
                if (n.fringe_bitset.isSet(octet)) {
                    // fringe is the default-route for all possible nodes below
                    const fringe_rank = n.fastFringeRank(octet) - 1;
                    const fringe_value = n.fringe_items.items[fringe_rank].value;
                    
                    // Reconstruct prefix for fringe
                    const fringe_bits = @as(u8, @intCast((depth + 1) * 8));
                    var fringe_addr = addr.*;
                    fringe_addr = fringe_addr.masked(fringe_bits);
                    const fringe_prefix = Prefix.init(&fringe_addr, fringe_bits);
                    
                    return node.LookupResult(V){
                        .prefix = fringe_prefix,
                        .value = fringe_value,
                        .ok = true,
                    };
                }
                
                // Go BART: leafNode case - medium frequency (branch prediction optimization)
                if (n.leaf_bitset.isSet(octet)) {
                    const leaf_rank = n.fastLeafRank(octet) - 1;
                    const leaf = n.leaf_items.items[leaf_rank];
                    if (leaf.prefix.containsAddr(addr.*)) {
                        return node.LookupResult(V){
                            .prefix = leaf.prefix,
                            .value = leaf.value,
                            .ok = true,
                        };
                    }
                    // reached a path compressed prefix, stop traversing
                    break;
                }
                
                // Go BART: *node case - descend down to next trie level
                // HOT PATH: usually normal node (branch prediction optimization)
                // Correction: only descend and calculate rank if children_bitset is set
                if (n.children_bitset.isSet(octet)) {
                    const rank_idx = n.fastChildrenRank(octet) - 1;
                    n = n.children_items.items[rank_idx];
                } else {
                    // leaf node or fringe node case, end traversal
                    break;
                }
            }
            
            // Go BART: start backtracking, unwind the stack
            while (depth < octets.len) {
                depth = depth & 0xf; // Go BART: BCE
                
                n = stack[depth];
                
                // Go BART: longest prefix match, skip if node has no prefixes
                // HOT PATH: usually prefixes exist (branch prediction optimization)
                if (n.prefixes_items.items.len != 0) {
                    const host_idx = base_index.hostIdx(octets[depth]);
                    
                    // CRITICAL FIX: Use Go BART's exact algorithm with IntersectionTop
                    // Go BART: if topIdx, ok := n.prefixes.IntersectionTop(lmp.BackTrackingBitset(idx)); ok
                    const bs = lookup_tbl.backTrackingBitset(host_idx);
                    
                    if (n.prefixes_bitset.intersectionTop(&bs)) |top_idx| {
                        // Go BART: Simple IntersectionTop result - return directly
                        const rank_idx = n.prefixes_bitset.rank(top_idx) - 1;
                        return node.LookupResult(V){
                            .prefix = undefined, // Go BART does not reconstruct prefix in Lookup
                            .value = n.prefixes_items.items[rank_idx],
                            .ok = true,
                        };
                    }
                }
                
                if (depth == 0) break;
                depth -= 1;
            }
            
            return node.LookupResult(V){
                .prefix = undefined,
                .value = undefined,
                .ok = false,
            };
        }
        
        /// IPv6 optimization lookup
        fn lookupIPv6Optimized(self: *const Self, addr: *const IPAddr) ?V {
            const octets = addr.asSlice();
            var n = self;
            var best_match: ?V = null;
            
            // 16-byte unrolled loop for cache efficiency
            inline for (0..16) |depth| {
                if (depth >= octets.len) break;
                const octet = octets[depth];
                
                // IPv6 optimization LPM
                const lpm_result = n.lmpGetOptimized(octet);
                if (lpm_result.ok) {
                    best_match = lpm_result.val;
                }
                
                // IPv6 fringe optimization
                if (n.fringe_bitset.isSet(octet)) {
                    const rank_idx = n.fringe_bitset.rank(octet) - 1;
                    best_match = n.fringe_items.items[rank_idx].value;
                }
                
                // Continue descent
                if (!n.children_bitset.isSet(octet)) break;
                const rank_idx = n.children_bitset.rank(octet) - 1;
                n = n.children_items.items[rank_idx];
            }
            
            return best_match;
        }
        
        /// high-speed LPM (IPv6 optimization)
        fn lpmGetFast(self: *const Self, octet: u8) struct { val: V, ok: bool } {
            const idx = base_index.hostIdx(octet);
            const result = self.lmpGetOptimized(idx);
            return .{ .val = result.val, .ok = result.ok };
        }
        
        // =================================================================
        // Phase 2 & 3: full API implementation
        // =================================================================
        
        /// contains - check if IP is contained
        /// Target: 1-2 ns/op (Go BART: 5.60 ns/op)
        pub fn contains(self: *const Self, addr: *const IPAddr) bool {
            // Go BART: if ip is invalid, return false
            if (!addr.isValid()) {
                return false;
            }
            return self.lookupOptimized(addr).ok;
        }
        
        /// get - exact prefix match (Go BART compatible)
        pub fn get(self: *const Self, pfx: *const Prefix) ?V {
            const ip = pfx.addr;
            const bits = pfx.bits;
            const octets = ip.asSlice();
            
            const max_depth_info = base_index.maxDepthAndLastBits(bits);
            const max_depth = max_depth_info.max_depth;
            const last_bits = max_depth_info.last_bits;
            
            var n = self;
            
            for (octets, 0..) |octet, depth| {
                // Go BART: first check terminal case
                if (depth == max_depth) {
                    // Terminal case: get directly from prefixes
                    const idx = base_index.pfxToIdx256(octet, last_bits);
                    if (n.prefixes_bitset.isSet(idx)) {
                        const rank_idx = n.prefixes_bitset.rank(idx) - 1;
                        return n.prefixes_items.items[rank_idx];
                    }
                    return null;
                }
                
                // Go BART: check child node
                if (!n.children_bitset.isSet(octet)) {
                    // Check if it's a leaf node
                    if (n.leaf_bitset.isSet(octet)) {
                        const leaf_rank = n.leaf_bitset.rank(octet) - 1;
                        const leaf = n.leaf_items.items[leaf_rank];
                        
                        if (leaf.prefix.eql(pfx.*)) {
                            return leaf.value;
                        }
                    } else if (n.fringe_bitset.isSet(octet)) {
                        if (base_index.isFringe(depth, bits)) {
                            const fringe_rank = n.fringe_bitset.rank(octet) - 1;
                            return n.fringe_items.items[fringe_rank].value;
                        }
                    }
                    return null;
                }
                
                // Go BART: check type of child and descend
                const rank_idx = n.children_bitset.rank(octet) - 1;
                n = n.children_items.items[rank_idx];
            }
            
            return null;
        }
        
        /// delete - prefix deletion (with recursive node cleanup)
        pub fn delete(self: *Self, pfx: *const Prefix) ?V {
            const result = self.deleteRecursive(pfx, 0);
            return result;
        }
        
        /// deleteRecursive - recursive deletion (with empty node cleanup on path)
        fn deleteRecursive(self: *Self, pfx: *const Prefix, depth: usize) ?V {
            const masked_pfx = pfx.masked();
            const ip = masked_pfx.addr;
            const bits = masked_pfx.bits;
            const octets = ip.asSlice();
            
            const max_depth_info = base_index.maxDepthAndLastBits(bits);
            const max_depth = max_depth_info.max_depth;
            const last_bits = max_depth_info.last_bits;
            
            if (depth >= octets.len) return null;
            
            const octet = octets[depth];
            
            // Terminal case: delete from this node
            if (depth == max_depth) {
                const idx = base_index.pfxToIdx256(octet, last_bits);
                if (self.prefixes_bitset.isSet(idx)) {
                    const rank_idx = self.prefixes_bitset.rank(idx) - 1;
                    const old_value = self.prefixes_items.items[rank_idx];
                    
                    // Remove from bitset
                    self.prefixes_bitset.clear(idx);
                    
                    // Remove from array by shifting
                    self.removePrefixItem(rank_idx);
                    self.prefixes_items.items.len -= 1;
                    
                    return old_value;
                }
                return null;
            }
            
            // Handle leaf nodes
            if (self.leaf_bitset.isSet(octet)) {
                const leaf_rank = self.leaf_bitset.rank(octet) - 1;
                const leaf = self.leaf_items.items[leaf_rank];
                
                if (leaf.prefix.eql(masked_pfx)) {
                    const old_value = leaf.value;
                    
                    // Remove from bitset
                    self.leaf_bitset.clear(octet);
                    
                    // Remove from array
                    self.removeLeafItem(leaf_rank);
                    self.leaf_items.items.len -= 1;
                    
                    return old_value;
                }
                return null;
            }
            
            // Handle fringe nodes  
            if (self.fringe_bitset.isSet(octet)) {
                if (base_index.isFringe(depth, bits)) {
                    const fringe_rank = self.fringe_bitset.rank(octet) - 1;
                    const old_value = self.fringe_items.items[fringe_rank].value;
                    
                    // Remove from bitset
                    self.fringe_bitset.clear(octet);
                    
                    // Remove from array
                    self.removeFringeItem(fringe_rank);
                    self.fringe_items.items.len -= 1;
                    
                    return old_value;
                }
                return null;
            }
            
            // Handle child nodes: recursive case
            if (self.children_bitset.isSet(octet)) {
                const rank_idx = self.children_bitset.rank(octet) - 1;
                if (rank_idx >= self.children_items.items.len) return null;
                
                const child = self.children_items.items[rank_idx];
                
                // Recursively delete from child
                const result = child.deleteRecursive(pfx, depth + 1);
                
                // After deletion, check if child is now empty
                if (result != null and child.isEmpty()) {
                    // Child is empty, remove it
                    self.removeChildNodeSafe(octet);
                }
                
                return result;
            }
            
            return null;
        }
        
        /// removeChildNodeSafe - remove child node safely (with deinit)
        fn removeChildNodeSafe(self: *Self, octet: u8) void {
            if (!self.children_bitset.isSet(octet)) return;
            
            const rank_idx = self.children_bitset.rank(octet) - 1;
            if (rank_idx >= self.children_items.items.len) return;
            
            // 子ノードを解放
            const child = self.children_items.items[rank_idx];
            child.deinit();
            
            // ビットセットから削除
            self.children_bitset.clear(octet);
            
            // 配列から削除（要素をシフト）
            self.removeChildItem(rank_idx);
            self.children_items.items.len -= 1;
            
            // 整合性チェック（デバッグ用）
            if (self.children_items.items.len != @as(u16, self.children_bitset.popcnt())) {
                // 整合性エラーが発生した場合の緊急処理
                self.children_bitset.clear(octet);
                self.children_items.items.len -= 1;
            }
        }
        
        /// cleanupEmptyNodes - clean up empty nodes
        fn cleanupEmptyNodes(self: *Self) void {
            // 子ノードから削除可能なものを特定
            var nodes_to_remove = std.ArrayList(u8).init(std.heap.page_allocator);
            defer nodes_to_remove.deinit();
            
            // 各子ノードをチェック
            for (0..256) |i| {
                const octet = @as(u8, @intCast(i));
                if (self.children_bitset.isSet(octet)) {
                    const rank_idx = self.children_bitset.rank(octet) - 1;
                    if (rank_idx < self.children_items.items.len) {
                        const child = self.children_items.items[rank_idx];
                        
                        // 子ノードが空になったかチェック
                        if (child.isEmpty()) {
                            nodes_to_remove.append(octet) catch {};
                        }
                    }
                }
            }
            
            // 空のノードを削除
            for (nodes_to_remove.items) |octet| {
                self.removeChildNode(octet);
            }
        }
        
        /// removeChildNode - remove child node safely
        fn removeChildNode(self: *Self, octet: u8) void {
            if (!self.children_bitset.isSet(octet)) return;
            
            const rank_idx = self.children_bitset.rank(octet) - 1;
            if (rank_idx >= self.children_items.items.len) return;
            
            // 子ノードを解放
            const child = self.children_items.items[rank_idx];
            child.deinit();
            
            // ビットセットから削除
            self.children_bitset.clear(octet);
            
            // 配列から削除（要素をシフト）
            self.removeChildItem(rank_idx);
            self.children_items.items.len -= 1;
        }
        
        /// removeChildItem - remove element from child node array
        fn removeChildItem(self: *Self, index: usize) void {
            if (index >= self.children_items.items.len) return;
            
            const move_count = self.children_items.items.len - index - 1;
            if (move_count > 0) {
                if (move_count <= 8) {
                    // small size is expanded loop moving forward
                    for (0..move_count) |i| {
                        self.children_items.items[index + i] = self.children_items.items[index + i + 1];
                    }
                } else {
                    // large size uses std.mem.copyForwards
                    std.mem.copyForwards(*Self, self.children_items.items[index..index + move_count], self.children_items.items[index + 1..index + 1 + move_count]);
                }
            }
            
            // clear last element for debugging
            if (self.children_items.items.len > 0) {
                self.children_items.items[self.children_items.items.len - 1] = undefined;
            }
        }
        
        /// removePrefixItem - remove element from prefixes array
        fn removePrefixItem(self: *Self, index: usize) void {
            if (index >= self.prefixes_items.items.len) return;
            
            const move_count = self.prefixes_items.items.len - index - 1;
            if (move_count > 0) {
                if (move_count <= 8) {
                    // small size is expanded loop moving forward
                    for (0..move_count) |i| {
                        self.prefixes_items.items[index + i] = self.prefixes_items.items[index + i + 1];
                    }
                } else {
                    // large size uses std.mem.copyForwards
                    std.mem.copyForwards(V, self.prefixes_items.items[index..index + move_count], self.prefixes_items.items[index + 1..index + 1 + move_count]);
                }
            }
            
            // clear last element for debugging
            if (self.prefixes_items.items.len > 0) {
                self.prefixes_items.items[self.prefixes_items.items.len - 1] = undefined;
            }
        }
        
        // =================================================================
        // Phase 3: Child type system integration (full compatibility)
        // =================================================================
        
        /// getChild - full compatibility with current Child(V)
        pub fn getChild(self: *const Self, octet: u8) ?Child(V) {
            // priority: children > leaf > fringe
            if (self.children_bitset.isSet(octet)) {
                const rank_idx = self.children_bitset.rank(octet) - 1;
                return Child(V){ .node = self.children_items.items[rank_idx] };
            }
            
            if (self.leaf_bitset.isSet(octet)) {
                const rank_idx = self.leaf_bitset.rank(octet) - 1;
                return Child(V){ .leaf = self.leaf_items.items[rank_idx] };
            }
            
            if (self.fringe_bitset.isSet(octet)) {
                const rank_idx = self.fringe_bitset.rank(octet) - 1;
                return Child(V){ .fringe = self.fringe_items.items[rank_idx] };
            }
            
            return null;
        }
        
        /// hasChild - check if child exists
        pub fn hasChild(self: *const Self, octet: u8) bool {
            return self.children_bitset.isSet(octet) or 
                   self.leaf_bitset.isSet(octet) or 
                   self.fringe_bitset.isSet(octet);
        }
        
        // =================================================================
        // Helper & Utility Functions
        // =================================================================
        
        /// size - total number of elements
        pub fn size(self: *const Self) usize {
            return @as(usize, self.prefixes_items.items.len) + 
                   @as(usize, self.children_items.items.len) + 
                   @as(usize, self.leaf_items.items.len) + 
                   @as(usize, self.fringe_items.items.len);
        }
        
        /// clone - deep copy (corrected version: children_bitset compatibility)
        pub fn clone(self: *const Self, allocator: std.mem.Allocator) *Self {
            const new_node = Self.init(allocator);
            
            // copy prefixes
            new_node.prefixes_bitset = self.prefixes_bitset;
            new_node.prefixes_items.appendSlice(self.prefixes_items.items) catch @panic("OOM");
            
            // deep copy of children (recursively cloning child nodes)
            new_node.children_bitset = self.children_bitset;
            for (self.children_items.items) |child| {
                const cloned_child = child.clone(allocator);
                new_node.children_items.append(cloned_child) catch @panic("OOM");
            }
            
            // copy leaf
            new_node.leaf_bitset = self.leaf_bitset;
            new_node.leaf_items.appendSlice(self.leaf_items.items) catch @panic("OOM");
            
            // copy fringe
            new_node.fringe_bitset = self.fringe_bitset;
            new_node.fringe_items.appendSlice(self.fringe_items.items) catch @panic("OOM");
            
            return new_node;
        }

        // =================================================================
        // Phase 2: LookupPrefix APIs - Go BART compatible
        // =================================================================
        
        /// LookupPrefix does a route lookup (longest prefix match) for pfx and
        /// returns the associated value and true, or false if no route matched.
        pub fn lookupPrefix(self: *const Self, pfx: *const Prefix) struct { val: V, ok: bool } {
            const result = self.lookupPrefixLPMInternal(pfx, false);
            return .{ .val = result.val, .ok = result.ok };
        }
        
        /// LookupPrefixLPM is similar to LookupPrefix,
        /// but it returns the lmp prefix in addition to value,ok.
        /// This method is about 20-30% slower than LookupPrefix and should only
        /// be used if the matching lpm entry is also required for other reasons.
        pub fn lookupPrefixLPM(self: *const Self, pfx: *const Prefix) struct { lmp_pfx: Prefix, val: V, ok: bool } {
            const result = self.lookupPrefixLPMInternal(pfx, true);
            return .{ .lmp_pfx = result.lmp_pfx, .val = result.val, .ok = result.ok };
        }
        
        /// Internal implementation of lookupPrefixLPM following Go BART algorithm exactly
        fn lookupPrefixLPMInternal(self: *const Self, pfx: *const Prefix, with_lpm: bool) struct { lmp_pfx: Prefix, val: V, ok: bool } {
            if (!pfx.isValid()) {
                return .{ .lmp_pfx = undefined, .val = undefined, .ok = false };
            }
            
            // Go BART: canonicalize the prefix
            const canonical_pfx = pfx.masked();
            
            const ip = canonical_pfx.addr;
            const bits = canonical_pfx.bits;
            const octets = ip.asSlice();
            
            const max_depth_info = base_index.maxDepthAndLastBits(bits);
            const max_depth = max_depth_info.max_depth;
            const last_bits = max_depth_info.last_bits;
            
            var n = self;
            
            // Go BART: record path to leaf node
            var stack: [16]*const Self = undefined;
            
            var depth: usize = 0;
            var octet: u8 = 0;
            
            // Go BART: find the last node on the octets path in the trie
            for (octets, 0..) |current_octet, d| {
                depth = d & 0xf; // Go BART: BCE
                
                if (depth > max_depth) {
                    depth -= 1;
                    break;
                }
                
                // Go BART: push current node on stack
                stack[depth] = n;
                octet = current_octet;
                
                // Go BART: go down in tight loop to leaf node
                if (!n.children_bitset.isSet(octet) and !n.leaf_bitset.isSet(octet) and !n.fringe_bitset.isSet(octet)) {
                    break;
                }
                
                // Go BART: leafNode case
                if (n.leaf_bitset.isSet(octet)) {
                    const leaf_rank = n.fastLeafRank(octet) - 1;
                    const leaf = n.leaf_items.items[leaf_rank];
                    
                    // Go BART: reached a path compressed prefix, stop traversing
                    if (leaf.prefix.bits > bits or !leaf.prefix.containsAddr(ip)) {
                        break;
                    }
                    return .{ .lmp_pfx = leaf.prefix, .val = leaf.value, .ok = true };
                }
                
                // Go BART: fringeNode case
                if (n.fringe_bitset.isSet(octet)) {
                    if (base_index.isFringe(depth, bits)) {
                        const fringe_rank = n.fastFringeRank(octet) - 1;
                        const fringe = n.fringe_items.items[fringe_rank];
                        return .{ .lmp_pfx = undefined, .val = fringe.value, .ok = true };
                    }
                    break;
                }
                
                // Go BART: *node case - descend down to next trie level
                // HOT PATH: usually normal node (branch prediction optimization)
                // Correction: only descend and calculate rank if children_bitset is set
                if (n.children_bitset.isSet(octet)) {
                    const rank_idx = n.fastChildrenRank(octet) - 1;
                    n = n.children_items.items[rank_idx];
                } else {
                    // leaf node or fringe node case, end traversal
                    break;
                }
            }
            
            // Go BART: start backtracking, unwind the stack
            var backtrack_depth: i32 = @as(i32, @intCast(depth));
            
            while (backtrack_depth >= 0) : (backtrack_depth -= 1) {
                const current_depth = @as(usize, @intCast(backtrack_depth)) & 0xf; // Go BART: BCE
                
                n = stack[current_depth];
                
                // Go BART: longest prefix match, skip if node has no prefixes
                if (n.prefixes_items.items.len == 0) {
                    continue;
                }
                
                // Go BART: only the lastOctet may have a different prefix len
                // all others are just host routes
                var idx: usize = 0;
                const current_octet: u8 = octets[current_depth];
                if (current_depth == max_depth) {
                    idx = base_index.pfxToIdx256(current_octet, last_bits);
                } else {
                    idx = base_index.hostIdx(current_octet);
                }
                
                // CRITICAL FIX: Use Go BART's exact algorithm with IntersectionTop
                // Go BART: manually inlined: lpmGet(idx)
                const bs = lookup_tbl.backTrackingBitset(idx);
                
                // Go BART: if topIdx, ok := n.prefixes.IntersectionTop(lmp.BackTrackingBitset(idx)); ok
                if (n.prefixes_bitset.intersectionTop(&bs)) |top_idx| {
                    // Go BART: Simple IntersectionTop result - process directly
                    const rank_idx = n.prefixes_bitset.rank(top_idx) - 1;
                    const val = n.prefixes_items.items[rank_idx];
                    
                    // Go BART: called from LookupPrefix
                    if (!with_lpm) {
                        return .{ .lmp_pfx = undefined, .val = val, .ok = true };
                    }
                    
                    // Go BART: called from LookupPrefixLPM
                    
                    // Go BART: get the pfxLen from depth and top idx
                    const pfx_len = base_index.pfxLen256(@intCast(current_depth), top_idx) catch {
                        // PfxLen256 error - fall through to continue backtracking
                        break;
                    };
                    
                    // Go BART: calculate the lmpPfx from incoming ip and new mask
                    var lmp_addr = ip;
                    lmp_addr = lmp_addr.masked(pfx_len);
                    const lmp_pfx = Prefix.init(&lmp_addr, pfx_len);
                    
                    return .{ .lmp_pfx = lmp_pfx, .val = val, .ok = true };
                }
                
                // If no valid match found in this depth, continue to next depth
            }
            
            return .{ .lmp_pfx = undefined, .val = undefined, .ok = false };
        }
        
        // =================================================================
        // Phase 3: Overlaps APIs - Go BART compatible
        // =================================================================
        
        /// overlaps - check if two nodes overlap
        /// Go BART compatible implementation
        pub fn overlaps(self: *const Self, other: *const Self, depth: usize) bool {
            const self_pfx_count = self.prefixes_items.items.len;
            const other_pfx_count = other.prefixes_items.items.len;
            const self_child_count = self.children_items.items.len;
            const other_child_count = other.children_items.items.len;
            
            // 1. Test if any routes overlap
            if (self_pfx_count > 0 and other_pfx_count > 0) {
                if (self.overlapsRoutes(other)) {
                    return true;
                }
            }
            
            // 2. Test if routes overlap any child
            // Swap nodes for optimization
            var n = self;
            var o = other;
            var n_pfx_count = self_pfx_count;
            var o_pfx_count = other_pfx_count;
            var n_child_count = self_child_count;
            var o_child_count = other_child_count;
            
            if (n_child_count > o_child_count) {
                n = other;
                o = self;
                n_pfx_count = other_pfx_count;
                o_pfx_count = self_pfx_count;
                n_child_count = other_child_count;
                o_child_count = self_child_count;
            }
            
            if (n_pfx_count > 0 and o_child_count > 0) {
                if (n.overlapsChildrenIn(o)) {
                    return true;
                }
            }
            
            // Symmetric reverse
            if (o_pfx_count > 0 and n_child_count > 0) {
                if (o.overlapsChildrenIn(n)) {
                    return true;
                }
            }
            
            // 3. Children with same octet in both nodes
            if (n_child_count == 0 or o_child_count == 0) {
                return false;
            }
            
            // No child with identical octet
            if (!n.children_bitset.intersectsAny(&o.children_bitset)) {
                return false;
            }
            
            return n.overlapsSameChildren(o, depth);
        }
        
        /// overlapsRoutes - check if routes between two nodes overlap
        fn overlapsRoutes(self: *const Self, other: *const Self) bool {
            // Some prefixes are identical, trivial overlap
            if (self.prefixes_bitset.intersectsAny(&other.prefixes_bitset)) {
                return true;
            }
            
            // Get the lowest idx (biggest prefix)
            const self_first_idx = self.prefixes_bitset.firstSet();
            const other_first_idx = other.prefixes_bitset.firstSet();
            
            if (self_first_idx == null or other_first_idx == null) {
                return false;
            }
            
            // Start with other min value
            var n_idx = other_first_idx.?;
            var o_idx = self_first_idx.?;
            
            var n_ok = true;
            var o_ok = true;
            
            // Zip range over both sets
            while (n_ok or o_ok) {
                if (n_ok) {
                    if (self.prefixes_bitset.nextSet(n_idx)) |next_idx| {
                        n_idx = next_idx;
                        if (other.lpmTest(n_idx)) {
                            return true;
                        }
                        if (n_idx == 255) {
                            n_ok = false;
                        } else {
                            n_idx += 1;
                        }
                    } else {
                        n_ok = false;
                    }
                }
                
                if (o_ok) {
                    if (other.prefixes_bitset.nextSet(o_idx)) |next_idx| {
                        o_idx = next_idx;
                        if (self.lpmTest(o_idx)) {
                            return true;
                        }
                        if (o_idx == 255) {
                            o_ok = false;
                        } else {
                            o_idx += 1;
                        }
                    } else {
                        o_ok = false;
                    }
                }
            }
            
            return false;
        }
        
        /// overlapsChildrenIn - check if prefixes overlap with children of the other node
        fn overlapsChildrenIn(self: *const Self, other: *const Self) bool {
            const pfx_count = self.prefixes_items.items.len;
            const child_count = other.children_items.items.len;
            
            // Heuristic: when to range vs bitset calc
            const magic_number = 15;
            const do_range = child_count < magic_number or pfx_count > magic_number;
            
            if (do_range) {
                // Range over children
                for (0..child_count) |i| {
                    const octet = other.children_bitset.nthSet(i) orelse continue;
                    if (self.lpmTest(base_index.hostIdx(octet))) {
                        return true;
                    }
                }
                return false;
            }
            
            // Bitset intersection approach
            var host_routes = BitSet256.init();
            
            // Union all allotted bitsets for prefixes
            for (0..pfx_count) |i| {
                const idx = self.prefixes_bitset.nthSet(i) orelse continue;
                // TODO: Need to implement idxToFringeRoutes equivalent
                // For now, use simplified approach
                host_routes.set(idx);
            }
            
            return host_routes.intersectsAny(&other.children_bitset);
        }
        
        /// overlapsSameChildren - check if child nodes with the same octet overlap
        fn overlapsSameChildren(self: *const Self, other: *const Self, depth: usize) bool {
            // Intersect the child bitsets
            const common_children = self.children_bitset.intersection(&other.children_bitset);
            
            var addr: u8 = 0;
            while (common_children.nextSet(addr)) |next_addr| {
                addr = next_addr;
                
                const self_child = self.getChildSafe(addr);
                const other_child = other.getChildSafe(addr);
                
                if (overlapsTwoChildren(self_child, other_child, depth + 1)) {
                    return true;
                }
                
                if (addr == 255) break;
                addr += 1;
            }
            
            return false;
        }
        
        /// overlapsTwoChildren - check if two child nodes overlap
        fn overlapsTwoChildren(self_child: Child(V), other_child: Child(V), depth: usize) bool {
            switch (self_child) {
                .node => |self_node| {
                    switch (other_child) {
                        .node => |other_node| {
                            return self_node.overlaps(other_node, depth);
                        },
                        .leaf => |other_leaf| {
                            return self_node.overlapsPrefixAtDepth(other_leaf.prefix, depth);
                        },
                        .fringe => {
                            return true;
                        },
                    }
                },
                .leaf => |self_leaf| {
                    switch (other_child) {
                        .node => |other_node| {
                            return other_node.overlapsPrefixAtDepth(self_leaf.prefix, depth);
                        },
                        .leaf => |other_leaf| {
                            return self_leaf.prefix.overlaps(&other_leaf.prefix);
                        },
                        .fringe => {
                            return true;
                        },
                    }
                },
                .fringe => {
                    return true;
                },
            }
        }
        
        /// overlapsPrefixAtDepth - check if prefixes overlap at a specific depth
        pub fn overlapsPrefixAtDepth(self: *const Self, pfx: Prefix, depth: usize) bool {
            const ip = pfx.addr;
            const bits = pfx.bits;
            const octets = ip.asSlice();
            
            const max_depth_info = base_index.maxDepthAndLastBits(bits);
            const max_depth = max_depth_info.max_depth;
            const last_bits = max_depth_info.last_bits;
            
            // Special case: 0.0.0.0/0 (default route) overlaps with ANY route in the table
            if (bits == 0) {
                // If table has any routes at all, it overlaps with 0.0.0.0/0
                // We need to check the entire table, not just this node
                return self.hasAnyRoutes();
            }
            
            var n = self;
            var current_depth = depth;
            
            while (current_depth < octets.len) {
                if (current_depth > max_depth) {
                    break;
                }
                
                const octet = octets[current_depth];
                
                // Full octet path in node trie
                if (current_depth == max_depth) {
                    return n.overlapsIdx(base_index.pfxToIdx256(octet, last_bits));
                }
                
                // Test if any route overlaps prefix so far
                if (n.prefixes_items.items.len > 0 and n.lpmTest(base_index.hostIdx(octet))) {
                    return true;
                }
                
                if (!n.children_bitset.isSet(octet)) {
                    return false;
                }
                
                // Get next child
                const child = n.getChildSafe(octet);
                switch (child) {
                    .node => |child_node| {
                        n = @ptrCast(@alignCast(child_node));
                        current_depth += 1;
                        continue;
                    },
                    .leaf => |child_leaf| {
                        return child_leaf.prefix.overlaps(&pfx);
                    },
                    .fringe => {
                        return true;
                    },
                }
            }
            
            return false;
        }
        
        /// overlapsIdx - check if overlap occurs at index
        fn overlapsIdx(self: *const Self, idx: u8) bool {
            // 1. Test if any route in this node overlaps prefix
            if (self.lpmTest(idx)) {
                return true;
            }
            
            // 2. Test if prefix overlaps any route in this node
            // Use bitset intersections
            var allotted_prefix_routes = BitSet256.init();
            allotted_prefix_routes.set(idx);
            
            if (allotted_prefix_routes.intersectsAny(&self.prefixes_bitset)) {
                return true;
            }
            
            // 3. Test if prefix overlaps any child in this node
            var allotted_host_routes = BitSet256.init();
            allotted_host_routes.set(idx);
            
            return allotted_host_routes.intersectsAny(&self.children_bitset);
        }
        
        /// Helper: Get child at specific octet (safe version)
        fn getChildSafe(self: *const Self, octet: u8) Child(V) {
            if (self.getChild(octet)) |child| {
                return child;
            }
            unreachable;
        }
        
        /// ⚡ memory access optimization: cached rank calculation
        inline fn fastChildrenRankCached(self: *const Self, idx: u8, is_set_known: bool) u16 {
            // most frequent case: fast path for single set bit
            if (self.children_items.items.len == 1) {
                // if result is known for single element, skip calculation
                return if (is_set_known) 1 else if (self.children_bitset.isSet(idx)) 1 else 0;
            }
            
            // general case: standard rank calculation
            return self.children_bitset.rank(idx);
        }
        
        /// ⚡ memory access optimization: cached rank calculation for prefixes
        inline fn fastPrefixesRankCached(self: *const Self, idx: u8, is_set_known: bool) u16 {
            // most frequent case: fast path for single set bit
            if (self.prefixes_items.items.len == 1) {
                // if result is known for single element, skip calculation
                return if (is_set_known) 1 else if (self.prefixes_bitset.isSet(idx)) 1 else 0;
            }
            
            // general case: standard rank calculation
            return self.prefixes_bitset.rank(idx);
        }
        
        /// ⚡ memory access optimization: cached rank calculation for leaf
        inline fn fastLeafRankCached(self: *const Self, idx: u8, is_set_known: bool) u16 {
            // most frequent case: fast path for single set bit
            if (self.leaf_items.items.len == 1) {
                // if result is known for single element, skip calculation
                return if (is_set_known) 1 else if (self.leaf_bitset.isSet(idx)) 1 else 0;
            }
            
            // general case: standard rank calculation
            return self.leaf_bitset.rank(idx);
        }
    };
}

/// DirectTable - Go BART Table structure full transplantation
/// Preparation for main Table integration
pub fn DirectTable(comptime V: type) type {
    return struct {
        const Self = @This();
        
        allocator: std.mem.Allocator,
        
        // DirectNode used (instead of sparse array)
        root4: *DirectNode(V),
        root6: *DirectNode(V), 
        size4: usize,
        size6: usize,
        
        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .root4 = DirectNode(V).init(allocator),
                .root6 = DirectNode(V).init(allocator),
                .size4 = 0,
                .size6 = 0,
            };
        }
        
        pub fn deinit(self: *Self) void {
            self.root4.deinit();
            self.root6.deinit();
        }
        
        /// insert - Go BART Insert full transplantation
        /// Target: 2.2 ns/op (Go BART: 12 ns/op)
        pub fn insert(self: *Self, pfx: Prefix, val: V) void {
            if (!pfx.isValid()) return;
            
            const canonical_pfx = pfx.masked();
            const is4 = canonical_pfx.addr.is4();
            const root = if (is4) self.root4 else self.root6;
            
            const was_new = !(try root.insertAtDepth(canonical_pfx, val, 0));
            if (was_new) {
                if (is4) {
                    self.size4 += 1;
                } else {
                    self.size6 += 1;
                }
            }
        }
        
        /// lookup - high-speed LPM
        pub fn lookup(self: *const Self, addr: *const IPAddr) ?V {
            // Go BART: if ip is invalid, return null
            if (!addr.isValid()) {
                return null;
            }
            const is4 = addr.is4();
            const root = if (is4) self.root4 else self.root6;
            return root.lookupOptimized(addr).value;
        }
        
        /// contains - high-speed containment check
        pub fn contains(self: *const Self, addr: *const IPAddr) bool {
            // Go BART: if ip is invalid, return false
            if (!addr.isValid()) {
                return false;
            }
            return self.lookup(addr) != null;
        }
        
        /// get - exact prefix match
        pub fn get(self: *const Self, pfx: *const Prefix) ?V {
            if (!pfx.isValid()) return null;
            
            const canonical_pfx = pfx.masked();
            const is4 = canonical_pfx.addr.is4();
            const root = if (is4) self.root4 else self.root6;
            
            return root.get(&canonical_pfx);
        }
        
        /// lookupPrefix - Go BART compatible LookupPrefix
        pub fn lookupPrefix(self: *const Self, pfx: *const Prefix) struct { val: V, ok: bool } {
            if (!pfx.isValid()) return .{ .val = undefined, .ok = false };
            
            const canonical_pfx = pfx.masked();
            const is4 = canonical_pfx.addr.is4();
            const root = if (is4) self.root4 else self.root6;
            
            return root.lookupPrefix(&canonical_pfx);
        }
        
        /// lookupPrefixLPM - Go BART compatible LookupPrefixLPM
        pub fn lookupPrefixLPM(self: *const Self, pfx: *const Prefix) struct { lmp_pfx: Prefix, val: V, ok: bool } {
            if (!pfx.isValid()) return .{ .lmp_pfx = undefined, .val = undefined, .ok = false };
            
            const canonical_pfx = pfx.masked();
            const is4 = canonical_pfx.addr.is4();
            const root = if (is4) self.root4 else self.root6;
            
            const result = root.lookupPrefixLPM(&canonical_pfx);
            return .{ .lmp_pfx = result.lmp_pfx, .val = result.val, .ok = result.ok };
        }
        
        /// size - total size
        pub fn size(self: *const Self) usize {
            return self.size4 + self.size6;
        }
        
        pub fn getSize4(self: *const Self) usize {
            return self.size4;
        }
        
        pub fn getSize6(self: *const Self) usize {
            return self.size6;
        }
        
        // =================================================================
        // Overlaps APIs - Go BART compatible
        // =================================================================
        
        /// overlapsPrefix - check if specified prefixes overlap with table
        pub fn overlapsPrefix(self: *const Self, pfx: *const Prefix) bool {
            if (!pfx.isValid()) {
                return false;
            }
            
            const canonical_pfx = pfx.masked();
            const is4 = canonical_pfx.addr.is4();
            const root = if (is4) self.root4 else self.root6;
            
            return root.overlapsPrefixAtDepth(canonical_pfx, 0);
        }
        
        /// overlaps - check if two tables overlap
        pub fn overlaps(self: *const Self, other: *const Self) bool {
            return self.overlaps4(other) or self.overlaps6(other);
        }
        
        /// overlaps4 - check if overlap occurs in IPv4
        pub fn overlaps4(self: *const Self, other: *const Self) bool {
            if (self.size4 == 0 or other.size4 == 0) {
                return false;
            }
            return self.root4.overlaps(other.root4, 0);
        }
        
        /// overlaps6 - check if overlap occurs in IPv6
        pub fn overlaps6(self: *const Self, other: *const Self) bool {
            if (self.size6 == 0 or other.size6 == 0) {
                return false;
            }
            return self.root6.overlaps(other.root6, 0);
        }
    };
}