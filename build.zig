const std = @import("std");
const print = std.debug.print;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "bart",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, 
    });
    lib.installHeader(b.path("src/bart.h"), "bart.h");
    b.installArtifact(lib);

    // Main executable
    const exe = b.addExecutable(.{
        .name = "zart",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    // BART Benchmark executable - matching Go BART's fulltable_test.go
    const bart_bench = b.addExecutable(.{
        .name = "bart_benchmark", 
        .root_source_file = b.path("src/bart_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(bart_bench);

    // Test executable
    const test_exe = b.addExecutable(.{
        .name = "test_basic",
        .root_source_file = b.path("src/test_basic.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(test_exe);

    // Run commands
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // BART Benchmark run command
    const bench_cmd = b.addRunArtifact(bart_bench);
    bench_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        bench_cmd.addArgs(args);
    }

    // Test run command  
    const test_cmd = b.addRunArtifact(test_exe);
    test_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        test_cmd.addArgs(args);
    }

    // Build steps
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const bench_step = b.step("bench", "Run BART benchmarks (matches Go BART's fulltable_test.go)");
    bench_step.dependOn(&bench_cmd.step);

    const test_step = b.step("test-basic", "Run basic tests");
    test_step.dependOn(&test_cmd.step);

    // Unit tests
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/table.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_unit_step = b.step("test", "Run unit tests");
    test_unit_step.dependOn(&run_lib_unit_tests.step);

    // Advanced benchmarks
    const advanced_bench = b.addExecutable(.{
        .name = "advanced_bench",
        .root_source_file = b.path("src/advanced_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(advanced_bench);

    const advanced_bench_cmd = b.addRunArtifact(advanced_bench);
    advanced_bench_cmd.step.dependOn(b.getInstallStep());

    const advanced_bench_step = b.step("advanced-bench", "Run advanced benchmarks");
    advanced_bench_step.dependOn(&advanced_bench_cmd.step);

    // vs Go benchmark
    const vs_go_bench = b.addExecutable(.{
        .name = "vs_go_benchmark",
        .root_source_file = b.path("src/vs_go_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(vs_go_bench);

    const vs_go_bench_cmd = b.addRunArtifact(vs_go_bench);
    vs_go_bench_cmd.step.dependOn(b.getInstallStep());

    const vs_go_bench_step = b.step("vs-go", "Run Go vs Zig comparison benchmarks");
    vs_go_bench_step.dependOn(&vs_go_bench_cmd.step);

    // Bitset tests
    const bitset_tests = b.addTest(.{
        .root_source_file = b.path("src/bitset256.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_bitset_tests = b.addRunArtifact(bitset_tests);
    test_unit_step.dependOn(&run_bitset_tests.step);

    // Lookup table tests
    const lookup_tests = b.addTest(.{
        .root_source_file = b.path("src/lookup_tbl.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lookup_tests = b.addRunArtifact(lookup_tests);
    test_unit_step.dependOn(&run_lookup_tests.step);
}
