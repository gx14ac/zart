# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is zart, a bitmap-based ART (Adaptive Radix Tree) routing table implementation written in Zig. The project provides a C-compatible library (`libbart.a`) with performance benchmarking capabilities focused on IP prefix routing lookups.

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

## Key Components

- **BartTable**: Main routing table structure with IPv4/IPv6 roots
- **NodePool**: Custom memory allocator for tree nodes
- **Bitmap-based lookups**: Uses 256-bit bitmaps for efficient prefix matching
- **C Compatibility**: All public APIs are C-exportable for integration with other languages

The codebase is performance-focused with extensive benchmarking infrastructure to measure insertion, lookup, and memory usage characteristics.