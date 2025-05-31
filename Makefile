ZIG ?= zig
TARGET ?= aarch64-macos

all: libbart.a

libbart.a: bart.zig bart.h
	$(ZIG) build-lib -OReleaseFast -target $(TARGET) bart.zig

clean:
	rm -f libbart.a

bench-csv:
	$(ZIG) build bench
	$(ZIG) build rt_bench
	$(ZIG) build advanced_bench

plot:
	python3 scripts/plot_benchmarks.py

all-bench: bench-csv plot