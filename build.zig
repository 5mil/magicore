//! Magicore build system.
//! Targets:
//!   zig build              — build kernel ELF
//!   zig build iso          — build bootable ISO (requires xorriso + limine)
//!   zig build run          — boot in QEMU via serial stdio
//!   zig build test         — run all subsystem unit tests on host

const std = @import("std");

pub fn build(b: *std.Build) void {
    // --- Freestanding x86_64 kernel target ---
    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag   = .freestanding,
        .abi      = .none,
        .cpu_features_add = std.Target.x86.featureSet(&.{
            .soft_float,
        }),
    });

    const optimize = b.standardOptimizeOption(.{});

    const kernel = b.addExecutable(.{
        .name             = "magicore",
        .root_source_file = b.path("arch/x86_64/boot.zig"),
        .target           = kernel_target,
        .optimize         = optimize,
        .code_model       = .kernel,
    });

    // Kernel linker script — places .requests, .text, .data, .bss
    kernel.setLinkerScriptPath(b.path("arch/x86_64/linker.ld"));
    kernel.root_module.link_libc = false;
    kernel.root_module.single_threaded = false;
    kernel.root_module.red_zone = false;   // disable red zone (required for interrupts)
    kernel.root_module.omit_frame_pointer = false;

    // --- Install kernel ELF ---
    const install_kernel = b.addInstallArtifact(kernel, .{});
    b.getInstallStep().dependOn(&install_kernel.step);

    // --- ISO build step ---
    // Requires: xorriso, limine installed on PATH
    // Usage: zig build iso
    const iso_step = b.step("iso", "Build bootable Limine ISO (requires xorriso + limine)");
    const make_iso = b.addSystemCommand(&.{
        "sh", "-c",
        \\ set -e
        \\ mkdir -p iso_root/boot/limine
        \\ cp zig-out/bin/magicore iso_root/boot/
        \\ cp misc/limine.conf iso_root/boot/limine/
        \\ limine bios-install iso_root 2>/dev/null || true
        \\ xorriso -as mkisofs \
        \\   -b boot/limine/limine-bios-cd.bin \
        \\   -no-emul-boot -boot-load-size 4 -boot-info-table \
        \\   --efi-boot boot/limine/limine-uefi-cd.bin \
        \\   -efi-boot-part --efi-boot-image \
        \\   -o magicore.iso iso_root
        \\ echo '[build] ISO ready: magicore.iso'
    });
    make_iso.step.dependOn(b.getInstallStep());
    iso_step.dependOn(&make_iso.step);

    // --- QEMU run step ---
    // Boots the ISO in QEMU with serial redirected to stdio.
    // Usage: zig build run
    const run_step = b.step("run", "Boot Magicore in QEMU");
    const qemu = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-M",          "q35",
        "-m",          "256M",
        "-cpu",        "host",
        "-smp",        "2",
        "-cdrom",      "magicore.iso",
        "-serial",     "stdio",
        "-display",    "none",
        "-no-reboot",
        "-no-shutdown",
        "-d",          "int,cpu_reset",  // log exceptions + resets
        "-D",          "qemu.log",
    });
    qemu.step.dependOn(iso_step);
    run_step.dependOn(&qemu.step);

    // --- QEMU run (KVM) step ---
    // Usage: zig build run-kvm  (Linux host with KVM only)
    const run_kvm_step = b.step("run-kvm", "Boot Magicore in QEMU with KVM acceleration");
    const qemu_kvm = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-M",          "q35,accel=kvm",
        "-m",          "256M",
        "-cpu",        "host",
        "-smp",        "4",
        "-cdrom",      "magicore.iso",
        "-serial",     "stdio",
        "-display",    "none",
        "-no-reboot",
        "-no-shutdown",
    });
    qemu_kvm.step.dependOn(iso_step);
    run_kvm_step.dependOn(&qemu_kvm.step);

    // --- Host unit tests per subsystem ---
    const test_step = b.step("test", "Run kernel unit tests on host");
    const host_target = b.standardTargetOptions(.{});

    const test_files = [_][]const u8{
        "drivers/uart16550.zig",
        "arch/x86_64/limine.zig",
        "arch/x86_64/init.zig",
        "kernel/mm/mm.zig",
        "kernel/mm/slab.zig",
        "kernel/mm/buddy.zig",
        "kernel/mm/vmm.zig",
        "kernel/sched/sched.zig",
        "kernel/sched/runqueue.zig",
        "kernel/ipc/ipc.zig",
        "kernel/syscall/table.zig",
        "kernel/io/ring.zig",
        "kernel/net/tcp.zig",
        "kernel/fs/ramfs.zig",
        "kernel/security/entropy.zig",
        "kernel/security/kaslr.zig",
        "kernel/security/syscall_gate.zig",
        "kernel/security/verified_boot.zig",
        "security/caps.zig",
        "fs/vfs.zig",
        "net/socket.zig",
        "lib/console.zig",
    };

    for (test_files) |tf| {
        const t = b.addTest(.{
            .root_source_file = b.path(tf),
            .target           = host_target,
            .optimize         = optimize,
        });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }
}
