//! Magicore x86_64 boot stub.
//! Entry point from bootloader (Limine-compatible).
//! Sets up stack, parses boot info, calls kmain.

const kmain = @import("../../kernel/main.zig").kmain;
const BootInfo = @import("init.zig").BootInfo;

/// Bootloader entry — stack not yet valid for Zig
export fn _start() callconv(.Naked) noreturn {
    // Set up a valid 64-bit stack before calling any Zig code
    asm volatile (
        \\lea boot_stack_top(%rip), %rsp
        \\xor %rbp, %rbp
        \\call zig_start
        \\ud2
    );
}

/// Called once stack is valid — parse boot info and call kmain
export fn zig_start() noreturn {
    // TODO: walk Limine boot protocol responses
    // TODO: build BootInfo from framebuffer/memmap/RSDP responses
    const boot_info: BootInfo = .{
        .memory_map = &.{},
        .kernel_phys_base = 0,
        .kernel_virt_base = 0xFFFFFFFF80000000,
        .rsdp_addr = 0,
        .fb_addr = 0,
        .fb_width = 0,
        .fb_height = 0,
        .fb_pitch = 0,
    };
    kmain(&boot_info);
}

/// Initial kernel stack — 64KB
var boot_stack: [64 * 1024]u8 align(16) linksection(".bss") = undefined;
export var boot_stack_top: u8 linksection(".bss") = undefined;
