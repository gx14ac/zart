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

| Operation   | zart (Zig) | bart (Go)  | Ratio         |
|-------------|------------|------------|---------------|
| InsertHot   | 8 ns/op    | 17.6 ns/op | zart 2.2x faster |
| DeleteHot   | 4 ns/op    | 5.3 ns/op  | equivalent    |
| GetHot      | 6 ns/op    | 5.2 ns/op  | equivalent    |
| LPM-hot     | 8 ns/op    | 9.7 ns/op  | zart 1.2x faster |

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

| Operation   | zart (Zig) | bart (Go)  | art (C)    |
|-------------|------------|------------|------------|
| InsertHot   | 8 ns/op    | 17.6 ns/op | -          |
| Insert      | 40 ns/op   | -          | 246 ns/op  |
| DeleteHot   | 4 ns/op    | 5.3 ns/op  | -          |
| Delete      | 42 ns/op   | -          | 127 ns/op  |
| GetHot      | 6 ns/op    | 5.2 ns/op  | -          |
| LPM         | 26 ns/op   | -          | 50 ns/op   |
| LPM-hot     | 8 ns/op    | 9.7 ns/op  | 4 ns/op    |

## Running

```
zig build bench -Doptimize=ReleaseFast
```
