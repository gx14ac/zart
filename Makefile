# BART (Binary Art) Routing Table - Makefile
# Build and test automation for the BART routing table implementation

# Build the library
.PHONY: build
build:
	zig build -Doptimize=ReleaseFast

# Run tests
.PHONY: test
test:
	zig build test

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
	@echo "  test         - Run tests"
	@echo "  clean        - Clean build artifacts"
	@echo "  bench        - Run basic benchmarks"
	@echo "  charts       - Generate performance comparison charts"
	@echo "  benchmark-charts - Run benchmarks and generate charts"
	@echo "  deps         - Install dependencies (nix)"
	@echo "  help         - Show this help message"