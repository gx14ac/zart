const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main library
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/table.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "zart",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    // Unit tests (table.zig - main entry point with all tests)
    const table_test_mod = b.createModule(.{
        .root_source_file = b.path("src/table.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib_unit_tests = b.addTest(.{
        .root_module = table_test_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Bitset tests
    const bitset_test_mod = b.createModule(.{
        .root_source_file = b.path("src/bitset256.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bitset_tests = b.addTest(.{
        .root_module = bitset_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(bitset_tests).step);

    // Lookup table tests
    const lookup_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lookup_tbl.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lookup_tests = b.addTest(.{
        .root_module = lookup_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(lookup_tests).step);

    // Netip tests (IPv4/IPv6 parser)
    const netip_test_mod = b.createModule(.{
        .root_source_file = b.path("src/netip.zig"),
        .target = target,
        .optimize = optimize,
    });
    const netip_tests = b.addTest(.{
        .root_module = netip_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(netip_tests).step);

    // AllowedIps tests
    const allowed_ips_test_mod = b.createModule(.{
        .root_source_file = b.path("src/allowed_ips.zig"),
        .target = target,
        .optimize = optimize,
    });
    const allowed_ips_tests = b.addTest(.{
        .root_module = allowed_ips_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(allowed_ips_tests).step);

    // Pool allocator tests
    const pool_test_mod = b.createModule(.{
        .root_source_file = b.path("src/pool_allocator.zig"),
        .target = target,
        .optimize = optimize,
    });
    const pool_tests = b.addTest(.{
        .root_module = pool_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(pool_tests).step);

    // Sparse array tests
    const sparse_test_mod = b.createModule(.{
        .root_source_file = b.path("src/sparse_array256_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sparse_tests = b.addTest(.{
        .root_module = sparse_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(sparse_tests).step);

    // Fuzz tests
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fuzz_tests = b.addTest(.{
        .root_module = fuzz_mod,
    });
    const fuzz_step = b.step("fuzz", "Run fuzz tests");
    fuzz_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    // Benchmarks
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_mod,
    });
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&b.addRunArtifact(bench_exe).step);

    // Freestanding kernel object (for OpenBSD integration)
    const kernel_step = b.step("kernel", "Build freestanding kernel object");
    const kernel_targets = [_]struct {
        name: []const u8,
        cpu_arch: std.Target.Cpu.Arch,
        code_model: std.builtin.CodeModel,
    }{
        .{ .name = "zart_kernel_amd64", .cpu_arch = .x86_64, .code_model = .kernel },
        .{ .name = "zart_kernel_arm64", .cpu_arch = .aarch64, .code_model = .small },
    };
    for (kernel_targets) |kt| {
        const kernel_mod = b.createModule(.{
            .root_source_file = b.path("src/kernel/root.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = kt.cpu_arch,
                .os_tag = .freestanding,
                .abi = .none,
            }),
            .optimize = .ReleaseFast,
            .code_model = kt.code_model,
            .red_zone = false,
            .omit_frame_pointer = false,
        });
        kernel_mod.addImport("zart_table", b.createModule(.{
            .root_source_file = b.path("src/table.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = kt.cpu_arch,
                .os_tag = .freestanding,
                .abi = .none,
            }),
            .optimize = .ReleaseFast,
            .code_model = kt.code_model,
            .red_zone = false,
            .omit_frame_pointer = false,
        }));
        const kernel_obj = b.addObject(.{
            .name = kt.name,
            .root_module = kernel_mod,
        });
        kernel_step.dependOn(&kernel_obj.step);

        const install = b.addInstallFile(kernel_obj.getEmittedBin(), b.fmt("kernel/{s}.o", .{kt.name}));
        kernel_step.dependOn(&install.step);
    }
}
