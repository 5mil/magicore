const std = @import("std");

pub fn build(b: *std.Build) void {
    // Magicore kernel build entry point
    // Target: freestanding x86_64 (no OS, no libc)
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const optimize = b.standardOptimizeOption(.{});

    // Kernel executable
    const kernel = b.addExecutable(.{
        .name = "magicore",
        .root_source_file = b.path("kernel/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Linker script for kernel memory layout
    kernel.setLinkerScriptPath(b.path("arch/x86_64/linker.ld"));

    // No libc — kernel is fully freestanding
    kernel.root_module.link_libc = false;
    kernel.root_module.single_threaded = false;

    b.installArtifact(kernel);

    // Per-subsystem unit tests
    const test_step = b.step("test", "Run kernel unit tests");

    const subsystems = [_][]const u8{
        "kernel/mm",
        "kernel/sched",
        "kernel/ipc",
        "kernel/syscall",
        "fs",
        "net",
        "lib",
    };

    for (subsystems) |sub| {
        const path = std.fmt.allocPrint(b.allocator, "{s}/tests.zig", .{sub}) catch unreachable;
        const t = b.addTest(.{
            .root_source_file = b.path(path),
            .target = b.standardTargetOptions(.{}),
            .optimize = optimize,
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
