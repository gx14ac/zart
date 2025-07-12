# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview: ZART

## What is this project?

This is **ZART**, a **world's fastest** BART (Binary Adaptive Radix Trie) routing table implementation written in Zig. The project provides a C-compatible library (`libbart.a`) with performance benchmarking capabilities focused on achieving **10-48x faster** performance than existing implementations like Go BART.

## Key Performance Achievements

- **Contains Operations**: 25-48x faster than Go BART (0.7ns vs 17-39ns)
- **Lookup Operations**: 16-32x faster than Go BART (3.8ns vs 61-120ns)  
- **IPv6 Performance**: Exceptional 48x speedup for IPv6 operations
- **Real Data Testing**: Validated with 100,000 real internet routing prefixes
- **Technology Stack**: SIMD optimization, precomputed lookup tables, optimized fixed arrays

ZART represents a breakthrough in routing table performance through advanced Zig language features and algorithmic innovations.

## Architecture

- **Core Library**: `src/main.zig` - Main BART table implementation with C-compatible exports
- **Node Management**: `src/node_pool.zig` - Memory pool for efficient node allocation
- **Bitmap Operations**: `src/bitset256.zig` - 256-bit bitmap operations for prefix matching
- **Base Indexing**: `src/base_index.zig` - Index calculation utilities
- **Lookup Tables**: `src/lookup_tbl.zig`, `src/pfx_routes_lookup_tbl.zig` - Optimized lookup structures

The library exposes C-compatible functions (`bart_create`, `bart_destroy`, etc.) and uses memory pooling for efficient node management. The bitmap-based approach optimizes memory usage and lookup performance for routing table operations.

## Build System

Uses Zig build system with multiple build targets:

**Build Commands:**
```bash
# Standard optimized build
make build
# or: zig build -Doptimize=ReleaseFast

# Debug build
make debug
# or: zig build

# Clean artifacts
make clean
```

**Testing:**
```bash
# Run all tests
make test
# or: zig build test

# Run specific test suites
zig build base_index_test  # Base index tests
```

**Benchmarking:**
```bash
# Individual benchmarks
make bench           # Basic performance evaluation
make rt-bench        # Realistic/production-like evaluation  
make advanced-bench  # Multithreaded performance evaluation

# Run all benchmarks and generate plots
make all-bench
```

## Development Environment

- **Nix**: Primary development environment setup via `nix develop`
- **Python**: Required for benchmark plotting (`scripts/plot_benchmarks.py`)
- **Test Data**: `testdata/prefixes.txt` contains routing prefixes for benchmarks

## Rules
常に全てのコードをBARTのアルゴリズム実装と比較してください。BR
BARTにない機能は実装しないでください。