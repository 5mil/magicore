//! Magicore ELF-64 loader.
//!
//! Loads a static ELF64 executable into an AddressSpace.
//! Supports:
//!   - ET_EXEC (static executables)
//!   - PT_LOAD segments (code, data, bss)
//! Does NOT support:
//!   - Dynamic linking (Phase 3)
//!   - Relocations (PIE, Phase 3)
//!   - Interpreter / ld-linux (Phase 5)
//!
//! Returns the entry point virtual address.

const std     = @import("std");
const mm      = @import("../mm/mm.zig");
const vmm     = @import("../mm/vmm.zig");
const pt      = @import("../mm/pgtable.zig");
const console = @import("../../lib/console.zig");

/// ELF-64 magic
const ELF_MAGIC: [4]u8 = .{ 0x7F, 'E', 'L', 'F' };
const ELFCLASS64: u8   = 2;
const ELFDATA2LSB: u8  = 1; // little-endian
const ET_EXEC: u16     = 2; // executable
const EM_X86_64: u16   = 62;
const PT_LOAD: u32     = 1;

/// ELF-64 header (64 bytes)
const Elf64Hdr = extern struct {
    e_ident:     [16]u8,
    e_type:      u16,
    e_machine:   u16,
    e_version:   u32,
    e_entry:     u64,
    e_phoff:     u64,  // program header offset
    e_shoff:     u64,
    e_flags:     u32,
    e_ehsize:    u16,
    e_phentsize: u16,
    e_phnum:     u16,
    e_shentsize: u16,
    e_shnum:     u16,
    e_shstrndx:  u16,
};

/// ELF-64 program header
const Elf64Phdr = extern struct {
    p_type:   u32,
    p_flags:  u32,  // PF_X=1, PF_W=2, PF_R=4
    p_offset: u64,  // offset in file
    p_vaddr:  u64,  // virtual address
    p_paddr:  u64,
    p_filesz: u64,  // bytes in file
    p_memsz:  u64,  // bytes in memory (>= filesz; padding = zeroed BSS)
    p_align:  u64,
};

/// Segment permission flags
const PF_X: u32 = 1;
const PF_W: u32 = 2;
const PF_R: u32 = 4;

pub const LoadError = error {
    NotElf,
    WrongClass,
    WrongEndian,
    WrongType,
    WrongArch,
    TruncatedHeader,
    TruncatedSegment,
    OutOfMemory,
    Overlap,
    AlreadyMapped,
};

/// Load a static ELF64 binary into `as`.
/// Returns the entry point virtual address.
pub fn load(as: *vmm.AddressSpace, elf: []const u8) LoadError!u64 {
    // Validate header
    if (elf.len < @sizeOf(Elf64Hdr)) return error.TruncatedHeader;
    const hdr: *const Elf64Hdr = @ptrCast(@alignCast(elf.ptr));

    if (!std.mem.eql(u8, hdr.e_ident[0..4], &ELF_MAGIC))  return error.NotElf;
    if (hdr.e_ident[4] != ELFCLASS64)   return error.WrongClass;
    if (hdr.e_ident[5] != ELFDATA2LSB)  return error.WrongEndian;
    if (hdr.e_type    != ET_EXEC)        return error.WrongType;
    if (hdr.e_machine != EM_X86_64)     return error.WrongArch;

    // Validate program header table bounds
    const ph_end = hdr.e_phoff + @as(u64, hdr.e_phnum) * hdr.e_phentsize;
    if (ph_end > elf.len) return error.TruncatedHeader;

    // Process PT_LOAD segments
    var i: usize = 0;
    while (i < hdr.e_phnum) : (i += 1) {
        const ph_off = hdr.e_phoff + i * hdr.e_phentsize;
        const ph: *const Elf64Phdr = @ptrCast(@alignCast(elf[ph_off..].ptr));
        if (ph.p_type != PT_LOAD) continue;
        if (ph.p_memsz == 0) continue;

        // Validate segment data is within ELF buffer
        const seg_end = ph.p_offset + ph.p_filesz;
        if (seg_end > elf.len) return error.TruncatedSegment;

        // Determine protection
        const prot = vmm.Prot{
            .read  = (ph.p_flags & PF_R) != 0,
            .write = (ph.p_flags & PF_W) != 0,
            .exec  = (ph.p_flags & PF_X) != 0,
            .user  = true,
        };

        // Determine region kind
        const kind: vmm.RegionKind = if ((ph.p_flags & PF_X) != 0)
            .code
        else if ((ph.p_flags & PF_W) != 0)
            .data
        else
            .rodata;

        // Align vaddr down to page boundary
        const page_vaddr = ph.p_vaddr & ~@as(u64, vmm.PAGE_SIZE - 1);
        const page_count = std.mem.alignForward(u64,
            (ph.p_vaddr - page_vaddr) + ph.p_memsz,
            vmm.PAGE_SIZE) / vmm.PAGE_SIZE;

        // Register VMA
        try as.mapRegion(.{
            .base = page_vaddr,
            .len  = page_count * vmm.PAGE_SIZE,
            .prot = prot,
            .kind = kind,
        });

        // Eagerly map pages and copy data
        var p: u64 = 0;
        while (p < page_count) : (p += 1) {
            const vaddr = page_vaddr + p * vmm.PAGE_SIZE;
            const phys  = try as.mapPage(vaddr, prot);
            const kvirt = mm.physToVirt(phys);
            const dst: [*]u8 = @ptrFromInt(kvirt);

            // Copy file data into page
            const file_page_off = (vaddr - ph.p_vaddr) + p * vmm.PAGE_SIZE;
            const copy_start  = ph.p_offset + file_page_off;
            const copy_avail  = if (copy_start < ph.p_offset + ph.p_filesz)
                ph.p_offset + ph.p_filesz - copy_start
            else
                0;
            const copy_len    = @min(copy_avail, vmm.PAGE_SIZE);

            if (copy_len > 0) {
                @memcpy(dst[0..copy_len], elf[copy_start..copy_start + copy_len]);
            }
            // Remainder is BSS (already zeroed by mapPage)
        }

        console.print("[elf] PT_LOAD vaddr=0x{X:0>16} memsz={} prot={s}{s}{s}\n", .{
            ph.p_vaddr, ph.p_memsz,
            if ((ph.p_flags & PF_R) != 0) "r" else "-",
            if ((ph.p_flags & PF_W) != 0) "w" else "-",
            if ((ph.p_flags & PF_X) != 0) "x" else "-",
        });
    }

    console.print("[elf] loaded, entry=0x{X:0>16}\n", .{hdr.e_entry});
    return hdr.e_entry;
}

test "ELF magic validation" {
    // Too-short buffer
    const short: []const u8 = "ELF";
    try std.testing.expectError(error.TruncatedHeader, load(undefined, short));
}

test "ELF bad magic" {
    var fake = [_]u8{0} ** @sizeOf(Elf64Hdr);
    fake[0] = 0x00; // wrong magic
    try std.testing.expectError(error.NotElf, load(undefined, &fake));
}
