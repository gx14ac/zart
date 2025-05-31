## zart
bitmap based art table.

## benchmark
``` sh
ZART Routing Table Benchmark
===========================

Benchmark Configuration 1:
------------------------

Inserting 1000 prefixes (/16):
  68.118.104.159/16
  87.111.55.145/16
  12.36.237.140/16
  ...
  41.186.252.247/16
  99.52.188.168/16
  28.195.135.144/16
Insert Performance: 16973317.94 prefixes/sec

Running 1000000 lookups:
  Lookup: 76.226.208.141 -> Match
  Lookup: 119.8.235.98 -> Match
  Lookup: 235.32.110.139 -> Match
  ...
  Lookup: 85.254.127.15 -> Match
  Lookup: 142.154.130.172 -> Match
  Lookup: 99.129.253.28 -> Match

Benchmark Results:
  Insert Time: 58.92μs
  Insert Rate: 16973317.94 prefixes/sec
  Lookup Time: 12.45ms
  Lookup Rate: 80332576.87 lookups/sec
  Match Rate: 100.00%

Benchmark Configuration 2:
------------------------

Inserting 10000 prefixes (/24):
  68.118.104.159/24
  87.111.55.145/24
  12.36.237.140/24
  ...
  58.204.112.200/24
  0.140.214.140/24
  136.241.62.193/24
Insert Performance: 38547974.88 prefixes/sec

Running 1000000 lookups:
  Lookup: 255.5.108.54 -> Match
  Lookup: 113.68.32.251 -> Match
  Lookup: 195.9.251.206 -> Match
  ...
  Lookup: 189.72.67.16 -> Match
  Lookup: 208.126.255.101 -> Match
  Lookup: 9.46.1.32 -> Match

Benchmark Results:
  Insert Time: 259.42μs
  Insert Rate: 38547974.88 prefixes/sec
  Lookup Time: 12.12ms
  Lookup Rate: 82517612.35 lookups/sec
  Match Rate: 100.00%

Benchmark Configuration 3:
------------------------

Inserting 100000 prefixes (/32):
  68.118.104.159/32
  87.111.55.145/32
  12.36.237.140/32
  ...
  191.76.253.34/32
  169.232.170.40/32
  49.104.59.221/32
Insert Performance: 39253539.00 prefixes/sec

Running 1000000 lookups:
  Lookup: 134.53.234.30 -> Match
  Lookup: 9.131.212.177 -> Match
  Lookup: 94.251.74.223 -> Match
  ...
  Lookup: 12.114.180.101 -> Match
  Lookup: 209.19.170.30 -> Match
  Lookup: 189.248.51.155 -> Match

Benchmark Results:
  Insert Time: 2.55ms
  Insert Rate: 39253539.00 prefixes/sec
  Lookup Time: 11.60ms
  Lookup Rate: 86193588.56 lookups/sec
  Match Rate: 100.00%
```

## Setup
`nix develop`

## CGO

## Ref
[art](https://github.com/hariguchi/art)
