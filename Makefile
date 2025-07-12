# BART (Binary Art) Routing Table - Makefile
# Build and test automation for the BART routing table implementation

# Default target
.PHONY: all
all: build

# Build the library
.PHONY: build
build:
	zig build -Doptimize=ReleaseFast

# Build with debug information
.PHONY: debug
debug:
	zig build

# Run tests
.PHONY: test
test:
	zig build test

# Run tests with debug information
.PHONY: test-debug
test-debug:
	zig build test -Doptimize=Debug

# Clean build artifacts
.PHONY: clean
clean:
	zig build clean
	rm -rf zig-out/
	rm -rf zig-cache/

# Run benchmarks
.PHONY: bench
bench:
	zig build bench -Doptimize=ReleaseFast

# Run realistic benchmarks
.PHONY: rt-bench
rt-bench:
	zig build rt_bench -Doptimize=ReleaseFast

# Run advanced benchmarks
.PHONY: advanced-bench
advanced-bench:
	zig build advanced_bench -Doptimize=ReleaseFast

# Run all benchmarks and generate graphs
.PHONY: all-bench
all-bench: bench rt-bench advanced-bench
	python3 scripts/plot_benchmarks.py

# Generate performance comparison charts
.PHONY: charts
charts:
	python3 scripts/generate_comparison_charts.py

# Generate performance comparison with fresh benchmark data
.PHONY: benchmark-charts
benchmark-charts: bench
	python3 scripts/generate_comparison_charts.py

# Install dependencies (if using nix)
.PHONY: deps
deps:
	nix develop

# Help target
.PHONY: help
help:
	@echo "Available targets:"
	@echo "  build        - Build the library (ReleaseFast)"
	@echo "  debug        - Build with debug information"
	@echo "  test         - Run tests"
	@echo "  test-debug   - Run tests with debug information"
	@echo "  clean        - Clean build artifacts"
	@echo "  bench        - Run basic benchmarks"
	@echo "  rt-bench     - Run realistic benchmarks"
	@echo "  advanced-bench - Run advanced benchmarks"
	@echo "  all-bench    - Run all benchmarks and generate graphs"
	@echo "  charts       - Generate performance comparison charts"
	@echo "  benchmark-charts - Run benchmarks and generate charts"
	@echo "  deps         - Install dependencies (nix)"
	@echo "  help         - Show this help message"