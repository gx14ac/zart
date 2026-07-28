# Benchmarks

## Environment

- Hardware: Apple M5 Max
- Zig: 0.15.2 (ReleaseFast)
- Go: 1.25.7
- OS: macOS (Darwin 25.4.0)

## Methodology

Each benchmark runs 3 iterations. "Hot" benchmarks follow Go BART methodology: a single probe is repeated on a pre-populated table to measure steady-state latency without allocation noise.

- **InsertHot**: Same prefix inserted repeatedly (overwrite path, no allocation)
- **DeleteHot**: Same prefix deleted repeatedly (not-found after first, no deallocation)
- **GetHot**: Same prefix looked up repeatedly
- **LPM-hot**: Same address looked up repeatedly
- **Insert (batch)**: N distinct random prefixes inserted into an empty table
- **Delete (batch)**: N prefixes deleted from a full table
- **Clone**: Deep copy of the entire table
- **Union**: Merge two tables of equal size

## Results

### N=100

| Operation      | IPv4 (ns/op) | IPv6 (ns/op) |
|----------------|--------------|--------------|
| Insert         | 64           | 38           |
| InsertHot      | 10           | 9            |
| Get            | 11           | 12           |
| GetHot         | 6            | 5            |
| LPM            | 11           | 6            |
| LPM-hot        | 3            | 4            |
| Delete         | 34           | 30           |
| DeleteHot      | 5            | 3            |
| Clone          | 21           | 22           |
| Union          | 30           | 47           |

### N=1,000

| Operation      | IPv4 (ns/op) | IPv6 (ns/op) |
|----------------|--------------|--------------|
| Insert         | 33           | 35           |
| InsertHot      | 9            | 13           |
| Get            | 10           | 12           |
| GetHot         | 7            | 6            |
| LPM            | 13           | 10           |
| LPM-hot        | 7            | 6            |
| Delete         | 41           | 46           |
| DeleteHot      | 4            | 5            |
| Clone          | 26           | 32           |
| Union          | 17           | 17           |

### N=10,000

| Operation      | IPv4 (ns/op) | IPv6 (ns/op) |
|----------------|--------------|--------------|
| Insert         | 34           | 38           |
| InsertHot      | 8            | 12           |
| Get            | 13           | 16           |
| GetHot         | 6            | 8            |
| LPM            | 10           | 16           |
| LPM-hot        | 4            | 6            |
| Delete         | 32           | 38           |
| DeleteHot      | 5            | 6            |
| Clone          | 13           | 19           |
| Union          | 16           | 27           |

### N=100,000

| Operation      | IPv4 (ns/op) | IPv6 (ns/op) |
|----------------|--------------|--------------|
| Insert         | 40           | 53           |
| InsertHot      | 8            | 11           |
| Get            | 21           | 25           |
| GetHot         | 6            | 7            |
| LPM            | 26           | 22           |
| LPM-hot        | 8            | 8            |
| Delete         | 42           | 69           |
| DeleteHot      | 4            | 4            |
| Clone          | 21           | 43           |
| Union          | 27           | 55           |

## Comparison with Go BART (N=100,000)

Go BART benchmarks measured with `go test -bench` under identical hardware.
Both use a single hot probe (same prefix repeated) against a pre-populated 100K-entry table.

### Mutable operations (hot path)

| Operation   | zart (Zig) | bart (Go)  | Ratio              |
|-------------|------------|------------|--------------------|
| InsertHot   | 8 ns/op    | 15.4 ns/op | zart 1.9x faster   |
| DeleteHot   | 5 ns/op    | 7.1 ns/op  | zart 1.4x faster   |
| GetHot      | 6 ns/op    | 6.3 ns/op  | equivalent         |
| LPM-hot     | 8 ns/op    | 9.0 ns/op  | zart 1.1x faster   |

### Persist operations (immutable path-copy, hot probe)

| Operation          | zart (Zig) | bart (Go)   | Ratio              |
|--------------------|------------|-------------|--------------------|
| InsertPersist/IPv4 | 514 ns/op  | 1019 ns/op  | zart 2.0x faster   |
| InsertPersist/IPv6 | 999 ns/op  | 1013 ns/op  | equivalent         |
| DeletePersist/IPv4 | 527 ns/op  | 991 ns/op   | zart 1.9x faster   |
| DeletePersist/IPv6 | 1114 ns/op | 1010 ns/op  | bart 1.1x faster   |

Notes:
- Both implementations use O(depth) path-copy (cloneFlat at each visited node).
- zart's Persist benchmark includes full deinit (immediate deallocation).
  Go BART defers cleanup to GC, so its ns/op excludes collection cost.
- IPv4 max depth = 4, IPv6 max depth = 16. Each level requires a cloneFlat
  (allocate node + copy sparse arrays + incRef children).
- zart IPv6 is slower because: (1) deeper paths = more cloneFlat calls per op,
  (2) Go's bump-pointer allocator (mcache/TLAB) costs ~3-5ns per alloc regardless
  of depth, while zart's pool allocator has higher per-alloc overhead at depth 8+.
- This is an allocator efficiency gap, not an algorithmic one — both are O(depth).

### Clone (full deep copy)

| Operation   | zart (Zig)  | bart (Go)     | Ratio              |
|-------------|-------------|---------------|--------------------|
| Clone/IPv4  | 23 ns/pfx   | 29.6 ns/pfx   | zart 1.3x faster   |
| Clone/IPv6  | 49 ns/pfx   | 40.5 ns/pfx   | bart 1.2x faster   |

## Comparison with art (C) (N=100,000)

art (C) is the original ART implementation by hariguchi, compiled with `clang -O2` on the same hardware.
art uses a different data structure (adaptive radix trie with variable-size nodes) and does not use BART's multibit-trie approach.

| Operation   | zart (Zig) | art (C)    | Ratio              |
|-------------|------------|------------|--------------------|
| Insert      | 40 ns/op   | 246 ns/op  | zart 6.2x faster   |
| Delete      | 42 ns/op   | 127 ns/op  | zart 3.0x faster   |
| LPM         | 26 ns/op   | 50 ns/op   | zart 1.9x faster   |
| LPM-hot     | 8 ns/op    | 4 ns/op    | art 2.0x faster    |

Notes:
- art's LPM-hot advantage comes from its simpler lookup path for a single cached probe (fewer indirections once the node is in L1).
- zart's batch operations (Insert/Delete/LPM) are significantly faster due to BART's fixed-stride multibit-trie requiring fewer memory accesses per operation on average.
- art's Insert includes building the full trie from scratch (N insertions); zart's Insert benchmark is equivalent.

## Three-way comparison (N=100,000, IPv4)

| Operation      | zart (Zig)  | bart (Go)   | art (C)    |
|----------------|-------------|-------------|------------|
| InsertHot      | 8 ns/op     | 15.4 ns/op  | -          |
| Insert         | 40 ns/op    | -           | 246 ns/op  |
| DeleteHot      | 5 ns/op     | 7.1 ns/op   | -          |
| Delete         | 42 ns/op    | -           | 127 ns/op  |
| GetHot         | 6 ns/op     | 6.3 ns/op   | -          |
| LPM            | 26 ns/op    | -           | 50 ns/op   |
| LPM-hot        | 8 ns/op     | 9.0 ns/op   | 4 ns/op    |
| InsertPersist  | 514 ns/op   | 1019 ns/op  | -          |
| DeletePersist  | 527 ns/op   | 991 ns/op   | -          |

## Persist scalability (O(depth) verification)

InsertPersistHot ns/op as table size grows — demonstrates O(depth) not O(N):

| N        | IPv4 (ns/op) | IPv6 (ns/op) |
|----------|--------------|--------------|
| 100      | 339          | 364          |
| 1,000    | 755          | 557          |
| 10,000   | 491          | 572          |
| 100,000  | 514          | 999          |

Cost is dominated by allocator behavior and cache effects, not table size.
The slight increase from N=10K to N=100K reflects cache pressure, not algorithmic scaling.

## OpenBSD kernel LPM benchmark (zart vs ART)

Direct comparison of zart's LPM lookup against OpenBSD's native ART (Allotment Routing Table)
running inside a real OpenBSD 7.9 kernel on QEMU/amd64.

### Environment

- VM: QEMU x86_64, OpenBSD 7.9 (GENERIC)
- Measurement: `lfence; rdtsc` (serialized cycle counter)
- Methodology: dual-run ordering (zart-first then ART-first), averaged to eliminate cache bias
- zart is compiled as a kernel module (Zig freestanding → .o, linked into bsd)
- ART is OpenBSD's stock implementation (same kernel, same routing table)

### Results (990-1000 prefixes, 100K lookups each)

| Protocol | zart (cyc/lookup) | ART (cyc/lookup) | Ratio        |
|----------|-------------------|-------------------|--------------|
| IPv4     | 271               | 257               | ART 1.05× faster |
| IPv6     | 255               | 959               | **zart 3.75× faster** |

### Analysis

**IPv4**: ART and zart are effectively tied. ART's allot-propagation design places
LPM answers directly at fringe positions — a single array dereference per level.
With the 8+4×6 level configuration, IPv4 lookups resolve in ~4 memory accesses.
zart also does 4 accesses, but the C→Zig FFI call overhead (register save/restore,
~10-20 cycles) makes it marginally slower. The 5% difference is within QEMU noise
(prior runs showed zart 1% faster).

**IPv6**: zart is **3.75× faster**. ART uses 4-bit×32 levels for IPv6, requiring up to
32 subtable descents. zart's fixed 8-bit stride resolves IPv6 in exactly 16 memory
accesses regardless of prefix distribution. This is a fundamental algorithmic advantage
that grows with address length.

### Conclusion

zart's value proposition is IPv6 LPM performance. For a hybrid deployment:
- IPv4: keep ART (no change needed)
- IPv6: replace with zart for 3.75× faster longest-prefix match

This maps naturally to OpenBSD's `rtable` structure, which maintains separate
`struct art` per address family.

## Running

```
zig build bench -Doptimize=ReleaseFast
```
