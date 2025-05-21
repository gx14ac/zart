ZIG ?= zig
TARGET ?= aarch64-macos

all: libbart.a

libbart.a: bart.zig bart.h
	$(ZIG) build-lib -OReleaseFast -target $(TARGET) bart.zig

clean:
	rm -f libbart.a