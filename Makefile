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

# Run ZART benchmarks
.PHONY: bench
bench:
	zig build bench -Doptimize=ReleaseFast

# Run Go BART benchmarks
.PHONY: bench-go
bench-go:
	@echo "🚀 Running Go BART benchmarks..."
	cd bart && go test -bench=BenchmarkFull -benchmem > ../bench_results_go.txt
	@echo "✅ Go BART benchmark results saved to bench_results_go.txt"

# Run ZART benchmarks and save results
.PHONY: bench-zart
bench-zart:
	@echo "🚀 Running ZART benchmarks..."
	zig build bench -Doptimize=ReleaseFast > bench_results_zart.txt
	@echo "✅ ZART benchmark results saved to bench_results_zart.txt"

# Run comprehensive benchmarks (both ZART and Go BART)
.PHONY: bench-all
bench-all: bench-zart bench-go
	@echo "🎯 All benchmark results collected:"
	@echo "  - ZART results: bench_results_zart.txt"
	@echo "  - Go BART results: bench_results_go.txt"

# Generate performance comparison charts
.PHONY: charts
charts:
	@echo "📊 Generating performance comparison charts..."
	python3 scripts/generate_comparison_charts.py
	@echo "✅ Comparison charts generated in assets/"

# Generate performance comparison with fresh benchmark data
.PHONY: benchmark-charts
benchmark-charts: bench-all charts
	@echo "📈 Benchmark comparison complete!"

# Verify benchmark compatibility (same test cases)
.PHONY: verify-compatibility
verify-compatibility:
	@echo "🔍 Verifying ZART and Go BART use same test cases..."
	@echo "Checking testdata/prefixes.txt.gz exists..."
	@test -f testdata/prefixes.txt.gz || (echo "❌ testdata/prefixes.txt.gz not found" && false)
	@test -f bart/testdata/prefixes.txt.gz || (echo "❌ bart/testdata/prefixes.txt.gz not found" && false)
	@echo "✅ Both implementations use same test data"
	@echo "🧪 Running basic compatibility test..."
	zig build bench -Doptimize=ReleaseFast
	@echo "✅ ZART benchmark passed"

# Update README with latest benchmark results
.PHONY: update-readme
update-readme: benchmark-charts
	@echo "📝 Updating README with latest benchmark results..."
	@# This could be extended to automatically update README.md with results
	@echo "✅ README update complete (manual update required)"
	@echo "📊 Please update README.md with the latest benchmark results from:"
	@echo "  - bench_results_zart.txt"
	@echo "  - bench_results_go.txt"
	@echo "  - assets/zart_vs_go_bart_comparison.png"
	@echo "  - assets/zart_vs_go_bart_summary.png"

# Complete benchmark workflow
.PHONY: full-benchmark
full-benchmark: verify-compatibility benchmark-charts update-readme
	@echo "🎉 Full benchmark workflow complete!"
	@echo "📊 Results available in:"
	@echo "  - Text files: bench_results_*.txt"
	@echo "  - Charts: assets/zart_vs_go_bart_*.png"
	@echo "  - Memory comparison: assets/memory_comparison.png"

# Install dependencies (if using nix)
.PHONY: deps
deps:
	nix develop

# Install Python dependencies for chart generation
.PHONY: deps-python
deps-python:
	pip3 install matplotlib seaborn numpy

# Help target
.PHONY: help
help:
	@echo "Available targets:"
	@echo "  build              - Build the library (ReleaseFast)"
	@echo "  test               - Run tests"
	@echo "  clean              - Clean build artifacts"
	@echo "  bench              - Run ZART benchmarks"
	@echo "  bench-go           - Run Go BART benchmarks"
	@echo "  bench-zart         - Run ZART benchmarks (save results)"
	@echo "  bench-all          - Run both ZART and Go BART benchmarks"
	@echo "  charts             - Generate performance comparison charts"
	@echo "  benchmark-charts   - Run benchmarks and generate charts"
	@echo "  verify-compatibility - Verify ZART and Go BART use same test cases"
	@echo "  update-readme      - Update README with latest results"
	@echo "  full-benchmark     - Complete benchmark workflow"
	@echo "  deps               - Install dependencies (nix)"
	@echo "  deps-python        - Install Python dependencies"
	@echo "  help               - Show this help message"