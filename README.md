# ZART

Zig implementation of a high-performance IPv4/IPv6 routing table based on the BART (Binary Adaptive Radix Trie) algorithm.

ZART is a faithful port of [gaissmai/bart](https://github.com/gaissmai/bart) (Go) with equivalent or better performance across all operations.

## Overview

ZART is a multibit-trie with a fixed stride length of 8 bits. Each node uses popcount-compressed sparse arrays to store prefixes and child pointers, with path compression via leaf and fringe node types. Longest prefix match (LPM) is performed using precalculated backtracking bitsets.

The complete binary tree at each node is represented as a 256-bit bitset that fits exactly in one cache line (4 x u64). All hot-path operations use hardware bit manipulation instructions (POPCNT, LZCNT, TZCNT).

## Requirements

- Zig 0.15.2 or later

## Build

```
zig build              # Build library
zig build test         # Run tests
zig build bench -Doptimize=ReleaseFast  # Run benchmarks
```

## Usage

```zig
const Table = @import("table.zig").Table;
const netip = @import("netip.zig");

var table = Table(u32).init(allocator);
defer table.deinit();

// Insert a prefix
var pfx = netip.Prefix.fromIPv4(192, 168, 1, 0, 24);
table.insert(&pfx, 100);

// Longest prefix match
const addr = netip.Addr.fromIPv4(192, 168, 1, 42);
if (table.lookup(&addr)) |value| {
    // value == 100
}

// Exact match
if (table.get(&pfx)) |value| {
    // value == 100
}

// Delete
table.delete(&pfx);
```

## Benchmarks

Apple M5 Max, N=100,000 random IPv4 prefixes, Zig 0.15.2 ReleaseFast / Go 1.25.7 / clang -O2.

| Operation   | zart (Zig) | bart (Go)  | art (C)    |
|-------------|------------|------------|------------|
| InsertHot   | 8 ns/op    | 17.6 ns/op | -          |
| Insert      | 40 ns/op   | -          | 246 ns/op  |
| DeleteHot   | 4 ns/op    | 5.3 ns/op  | -          |
| Delete      | 42 ns/op   | -          | 127 ns/op  |
| GetHot      | 6 ns/op    | 5.2 ns/op  | -          |
| LPM         | 26 ns/op   | -          | 50 ns/op   |
| LPM-hot     | 8 ns/op    | 9.7 ns/op  | 4 ns/op    |

Notes:
- Hot benchmarks repeat a single probe on a warm table (Go BART methodology).
- Batch benchmarks insert/delete N distinct prefixes.
- art (C) does not have separate hot/batch Insert; its Insert builds the table from scratch.

Full results across all table sizes and IPv4/IPv6: [BENCHMARKS.md](BENCHMARKS.md)

## API Reference

### Mutable Operations

```
insert(pfx, val)       Insert or overwrite a prefix.
delete(pfx)            Remove a prefix.
get(pfx)               Exact-match lookup. Returns value or null.
lookup(addr)           Longest prefix match by address.
lookupPrefix(pfx)      Longest prefix match by prefix.
lookupPrefixLPM(pfx)   LPM returning both the matched prefix and value.
overlaps(other)        True if two tables share any address space.
Union(other)           Merge all entries from other into self.
Clone(allocator)       Deep copy of the table.
size() / size4() / size6()  Number of entries.
```

### Persistent (COW) Operations

These return a new table, leaving the original unchanged. Suitable for concurrent-reader scenarios.

```
InsertPersist(pfx, val)       New table with prefix added.
DeletePersist(pfx)            New table with prefix removed.
GetAndDeletePersist(pfx)      New table + the deleted value.
UpdatePersist(pfx, cb)        New table with value transformed by callback.
```

## Source Layout

```
src/
  table.zig             Public Table API, IPv4/IPv6 dispatch
  node.zig              Node structure, recursive insert/delete/lookup/union
  sparse_array256.zig   Popcount-compressed sparse array with capacity growth
  bitset256.zig         256-bit bitset (POPCNT/LZCNT/TZCNT)
  netip.zig             IP address and prefix types
  base_index.zig        ART baseIndex mapping (prefix to complete binary tree index)
  pool_allocator.zig    Slab-based memory pool
  bench.zig             Benchmark suite
bart/
  Go BART source (reference implementation for verification)
```

## Design Decisions

### Slab Pool Allocator

The default `page_allocator` issues a syscall per allocation. ZART provides a slab allocator (`pool_allocator.zig`) that acquires 16 KB pages and partitions them into fixed-size slots across 10 size classes (16 B to 8 KB). Freed objects return to a per-class free list for O(1) reuse. This eliminates the allocation overhead that dominates insert/delete in a pointer-based trie.

### Capacity-based Sparse Array

Go slices grow with amortized O(1) append via doubling capacity. The original Zig implementation called `realloc` on every single insert (growing by 1 element). ZART adopts the same doubling strategy: insertions within existing capacity require no allocator call, and deletions shrink only the logical length without releasing memory. This matches Go's allocation behavior.

### Path Compression

Prefixes that would occupy a single-child subtree are stored inline as leaf or fringe nodes, avoiding unnecessary node allocations. A leaf stores the full prefix and value. A fringe stores only a value (the prefix is implied by position in the trie at an octet boundary).

## Testing

```
zig build test
```

Runs 135 tests covering:

- Sparse array operations (insert, delete, update, copy, capacity growth)
- Bitset operations (rank, select, intersection)
- Node operations (insert, delete, lookup, union, clone, overlaps)
- Table-level IPv4/IPv6 operations
- Pool allocator correctness (allocation, free-list reuse, integration with Table)
- Edge cases (sub-octet prefixes, mixed IPv4/IPv6, persistent operations)

## License

MIT
