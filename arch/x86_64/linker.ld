/* Magicore x86_64 kernel linker script — Limine higher-half */
/* Limine loads kernel at KERNEL_VIRT_BASE + phys offset     */

OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

KERNEL_VIRT_BASE = 0xFFFFFFFF80000000;

SECTIONS {
    . = KERNEL_VIRT_BASE;

    /* Limine protocol requests — must be in a named section */
    .requests ALIGN(8) : AT(ADDR(.requests) - KERNEL_VIRT_BASE) {
        KEEP(*(.requests))
    }

    .text ALIGN(4096) : AT(ADDR(.text) - KERNEL_VIRT_BASE) {
        KEEP(*(.text.boot))
        *(.text .text.*)
    }

    .rodata ALIGN(4096) : AT(ADDR(.rodata) - KERNEL_VIRT_BASE) {
        *(.rodata .rodata.*)
    }

    .data ALIGN(4096) : AT(ADDR(.data) - KERNEL_VIRT_BASE) {
        *(.data .data.*)
    }

    .bss ALIGN(4096) : AT(ADDR(.bss) - KERNEL_VIRT_BASE) {
        *(COMMON)
        *(.bss .bss.*)
    }

    /DISCARD/ : {
        *(.comment)
        *(.note.*)
        *(.eh_frame)
    }
}
