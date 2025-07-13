# Contributing to ZART

We welcome contributions to ZART! This document provides guidelines for contributing to ensure high academic and technical standards.

## Code of Conduct

This project adheres to academic research standards of collaboration, respect, and integrity. By participating, you agree to maintain professional discourse and cite prior work appropriately.

## Development Process

### Setting Up Development Environment

```bash
# Clone the repository
git clone https://github.com/gx14ac/zart.git
cd zart

# Install Zig 0.14.1 or later
# Follow: https://ziglang.org/download/

# Run tests to verify setup
zig test src/table.zig
zig test src/concurrent_test.zig

# Run benchmarks
zig build vs-go -Doptimize=ReleaseFast
```

### Contribution Types

1. **Algorithm Optimizations**: Performance improvements with academic rigor
2. **Concurrent Programming**: Lock-free and parallel algorithm enhancements
3. **Documentation**: Technical documentation and academic references
4. **Testing**: Comprehensive test coverage and benchmarking
5. **Bug Fixes**: Issue resolution with regression test inclusion

### Development Guidelines

#### Code Quality Standards

- **Academic Documentation**: All algorithms must include academic references and complexity analysis
- **Performance Focus**: Include benchmarks demonstrating performance characteristics against Go BART baseline
- **Memory Safety**: All code must be memory-safe and avoid undefined behavior
- **Concurrent Safety**: Thread-safe implementations must be proven correct
- **IPv6 Optimization**: Maintain or improve current IPv6 performance leadership (3.28× contains, 6.69× lookup)
- **Insert Efficiency**: Preserve efficient sparse array operations using @memcpy for optimal performance

#### Code Style

```zig
// Use clear, descriptive function names
pub fn insertOptimizedLPM(self: *Self, prefix: *const Prefix, value: V) void {
    // Academic-style comments explaining algorithm choices
    // Reference: [Paper citation] - algorithm complexity O(log n)
}

// Prefer explicit over implicit
const max_depth: usize = prefix.bits / 8;
const lookup_result: LookupResult(V) = self.lookup(addr);
```

#### Testing Requirements

- **Unit Tests**: All public APIs must have comprehensive test coverage
- **Performance Tests**: Include benchmarks comparing with reference implementations
- **Concurrent Tests**: Multi-threaded safety verification
- **Integration Tests**: End-to-end scenario testing

### Pull Request Process

1. **Academic Rigor**
   - Include references to relevant academic papers
   - Provide complexity analysis for algorithmic changes
   - Demonstrate performance improvements with benchmarks

2. **Technical Review**
   - Ensure all tests pass: `zig build test`
   - Include performance regression testing
   - Verify concurrent correctness where applicable

3. **Documentation**
   - Update README.md for new features
   - Include inline documentation for complex algorithms
   - Update PERFORMANCE_ACHIEVEMENTS.md for optimizations

### Benchmarking Standards

All performance claims must be substantiated with reproducible benchmarks against Go BART baseline:

```bash
# Standard benchmark suite (must maintain current performance levels)
make full-benchmark

# Performance regression testing
zig build vs-go -Doptimize=ReleaseFast

# Concurrent performance testing
zig test src/concurrent_test.zig -Doptimize=ReleaseFast
```

**Performance Expectations:**
- **IPv6 Operations**: Maintain performance leadership (>3× advantage for contains/lookup)
- **IPv4 Operations**: Competitive performance (~1.4× advantage for lookup operations)
- **Insert Operations**: Consistent scaling characteristics across dataset sizes
- **Memory Efficiency**: Bounded allocation patterns with predictable growth

**Regression Prevention:**
- No operation should regress beyond 10% of baseline performance
- IPv6 advantage must be preserved (critical differentiator)
- Insert efficiency improvements should be maintained
- All optimizations must include performance validation

### Academic Citations

When referencing academic work:

```zig
/// Implementation based on:
/// [1] Leis, V., et al. "The adaptive radix tree: ARTful indexing for main-memory databases."
///     ICDE 2013. DOI: 10.1109/ICDE.2013.6544812
/// [2] Morrison, D. R. "PATRICIA—practical algorithm to retrieve information coded in alphanumeric."
///     Journal of the ACM, 1968.
```

### Issue Reporting

When reporting issues:

1. **Environment Details**: Zig version, OS, hardware specifications
2. **Reproducible Example**: Minimal code example demonstrating the issue
3. **Expected vs Actual**: Clear description of incorrect behavior
4. **Performance Context**: For performance issues, include benchmark data

### Feature Requests

For new features:

1. **Academic Justification**: Reference relevant research or algorithmic innovations
2. **Performance Analysis**: Expected complexity and performance characteristics
3. **Use Cases**: Concrete scenarios where the feature provides value
4. **Implementation Approach**: High-level technical approach

### Research Collaboration

ZART encourages academic collaboration building on current achievements:

**Current Research Achievements:**
- **IPv6 Algorithm Optimization**: 3.28× faster contains, 6.69× faster lookup operations
- **Efficient Memory Operations**: @memcpy-based sparse array optimizations
- **SIMD Integration**: Vectorized bit operations for high-performance routing
- **Concurrent Safety**: Multiple programming models with formal verification

**Active Research Areas:**
- **Algorithm Research**: Novel routing table algorithms and optimization techniques
- **Systems Research**: Concurrent programming and memory management innovations  
- **Performance Research**: Comparative analysis and algorithmic complexity studies
- **IPv6 Specialization**: Further optimization for modern internet infrastructure
- **Large-Scale Optimization**: Insert performance improvements for internet-scale datasets

### Licensing

By contributing, you agree that your contributions will be licensed under the MIT License.

### Academic Recognition

Significant algorithmic contributions may be eligible for co-authorship on academic publications derived from this work. Please indicate interest in academic collaboration in your contribution.

### Getting Help

- **Technical Questions**: Create detailed GitHub issues
- **Academic Discussions**: Reference relevant papers and theoretical foundations
- **Performance Questions**: Include benchmark data and analysis

Thank you for contributing to advancing the state of routing table implementations! 