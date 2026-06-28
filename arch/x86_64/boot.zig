//! Magicore x86_64 boot stub — Limine protocol v8.
//! _start is the first Zig instruction after Limine hands off.
//! At entry:
//!   - We are in long mode (64-bit)
//!   - Limine has set up a valid stack
//!   - Limine responses are populated in .requests section
//!   - Interrupts are disabled
//!   - We must NOT return from _start

const std       = @import("std");
const limine    = @import("limine.zig");
const init      = @import("init.zig");
const uart      = @import("../../drivers/uart16550.zig");
const console   = @import("../../lib/console.zig");
const mm        = @import("../../kernel/mm/mm.zig");
const kmain_mod = @import("../../kernel/main.zig");

/// Kernel entry point — called by Limine in long mode
/// Limine guarantees: 64-bit, 16KB stack, higher-half mapped
export fn _start() callconv(.C) noreturn {
    // 1. Serial console first — before anything can fail silently
    uart.initKernelUart();
    console.earlyInit(&uart.kernel_uart);

    console.print("\n", .{});
    console.print("  ███╗   ███╗ █████╗  ██████╗ ██╗ ██████╗ ██████╗ ██████╗ ███████╗\n", .{});
    console.print("  ████╗ ████║██╔══██╗██╔════╝ ██║██╔════╝██╔═══██╗██╔══██╗██╔════╝\n", .{});
    console.print("  ██╔████╔██║███████║██║  ███╗██║██║     ██║   ██║██████╔╝█████╗  \n", .{});
    console.print("  ██║╚██╔╝██║██╔══██║██║   ██║██║██║     ██║   ██║██╔══██╗██╔══╝  \n", .{});
    console.print("  ██║ ╚═╝ ██║██║  ██║╚██████╔╝██║╚██████╗╚██████╔╝██║  ██║███████╗\n", .{});
    console.print("  ╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚═╝ ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝\n", .{});
    console.print("  Magicore v0.1.0 — No C. No spaghetti. No 40-year debt.\n\n", .{});

    // 2. Validate critical Limine responses
    const memmap_resp = limine.memmap_request.response orelse {
        console.panic("Limine did not provide memory map", .{});
    };
    const kaddr_resp = limine.kaddr_request.response orelse {
        console.panic("Limine did not provide kernel address", .{});
    };
    const hhdm_resp = limine.hhdm_request.response orelse {
        console.panic("Limine did not provide HHDM offset", .{});
    };

    console.print("[boot] kernel phys=0x{X:0>16} virt=0x{X:0>16}\n", .{
        kaddr_resp.physical_base,
        kaddr_resp.virtual_base,
    });
    console.print("[boot] HHDM offset=0x{X:0>16}\n", .{hhdm_resp.offset});
    console.print("[boot] memory map entries: {}\n", .{memmap_resp.entry_count});

    // 3. Print memory map summary
    var usable_pages: u64 = 0;
    for (memmap_resp.entries[0..memmap_resp.entry_count]) |entry| {
        const kind_str: []const u8 = switch (entry.kind) {
            .usable                 => "USABLE",
            .reserved               => "RESERVED",
            .acpi_reclaimable       => "ACPI RECLAIMABLE",
            .acpi_nvs               => "ACPI NVS",
            .bad_memory             => "BAD",
            .bootloader_reclaimable => "BOOTLOADER RECLAIMABLE",
            .kernel_and_modules     => "KERNEL+MODULES",
            .framebuffer            => "FRAMEBUFFER",
        };
        console.print("[mmap] 0x{X:0>12}–0x{X:0>12}  {s}\n", .{
            entry.base,
            entry.base + entry.length,
            kind_str,
        });
        if (entry.kind == .usable) {
            usable_pages += entry.length / 4096;
        }
    }
    console.print("[boot] usable RAM: {} pages ({} MiB)\n\n", .{
        usable_pages,
        (usable_pages * 4096) / (1024 * 1024),
    });

    // 4. Build BootInfo for kmain
    const boot_info = buildBootInfo(memmap_resp, kaddr_resp, hhdm_resp);

    // 5. Hand off to kmain — does not return
    kmain_mod.kmain(&boot_info);
}

/// Convert Limine memory map to Magicore BootInfo
fn buildBootInfo(
    memmap: *limine.MemMapResponse,
    kaddr:  *limine.KernelAddressResponse,
    hhdm:   *limine.HhdmResponse,
) init.BootInfo {
    // Static buffer for converted memory map entries (max 256 entries)
    const MAX_ENTRIES = 256;
    const S = struct {
        var entries: [MAX_ENTRIES]mm.MemMapEntry = undefined;
        var count: usize = 0;
    };
    S.count = 0;

    const n = @min(memmap.entry_count, MAX_ENTRIES);
    for (memmap.entries[0..n]) |entry| {
        S.entries[S.count] = .{
            .base = entry.base,
            .len  = entry.length,
            .kind = switch (entry.kind) {
                .usable, .bootloader_reclaimable => .free,
                .acpi_reclaimable, .acpi_nvs     => .acpi,
                .bad_memory                      => .bad,
                else                             => .reserved,
            },
        };
        S.count += 1;
    }

    // Framebuffer from Limine (if present)
    const fb = limine.framebuffer_request.response;
    const fb_addr:   u64 = if (fb != null and fb.?.framebuffer_count > 0) fb.?.framebuffers[0].address   else 0;
    const fb_width:  u32 = if (fb != null and fb.?.framebuffer_count > 0) @intCast(fb.?.framebuffers[0].width)  else 0;
    const fb_height: u32 = if (fb != null and fb.?.framebuffer_count > 0) @intCast(fb.?.framebuffers[0].height) else 0;
    const fb_pitch:  u32 = if (fb != null and fb.?.framebuffer_count > 0) @intCast(fb.?.framebuffers[0].pitch)  else 0;

    return .{
        .memory_map        = S.entries[0..S.count],
        .kernel_phys_base  = kaddr.physical_base,
        .kernel_virt_base  = kaddr.virtual_base,
        .hhdm_offset       = hhdm.offset,
        .rsdp_addr         = if (limine.rsdp_request.response) |r| r.address else 0,
        .fb_addr           = fb_addr,
        .fb_width          = fb_width,
        .fb_height         = fb_height,
        .fb_pitch          = fb_pitch,
    };
}
