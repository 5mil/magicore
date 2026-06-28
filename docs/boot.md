# Magicore Boot Process

## Overview

Magicore uses the [Limine](https://github.com/limine-bootloader/limine) bootloader (v8 protocol).
Limine is modern, fast, and handles the dirty work of transitioning to 64-bit long mode,
setting up a stack, mapping the higher half, and providing a structured handoff.

Our boot path is deliberately minimal:

```
BIOS/UEFI firmware
  └─ Limine bootloader
       └─ _start()  (arch/x86_64/boot.zig)
            ├─ UART console init (drivers/uart16550.zig)
            ├─ Print boot banner
            ├─ Validate Limine responses (memmap, kaddr, hhdm)
            ├─ Print memory map
            ├─ Build BootInfo struct
            └─ kmain()  (kernel/main.zig)
                 ├─ arch::init()   — GDT, IDT, CPU features
                 ├─ mm::init()     — physical frame allocator
                 ├─ sched::init()  — per-CPU run queues
                 ├─ ipc::init()    — channel primitives
                 ├─ syscall::init()— dispatch table
                 └─ sched::start() — begin scheduling, never returns
```

## Limine Requests

All Limine requests are declared in `arch/x86_64/limine.zig`
and placed in the `.requests` ELF section:

| Request | Purpose |
|---|---|
| `memmap_request` | Physical memory map from firmware |
| `kaddr_request` | Kernel physical + virtual base addresses |
| `hhdm_request` | Higher-half direct map offset |
| `framebuffer_request` | Framebuffer address, size, pitch |
| `rsdp_request` | ACPI RSDP pointer |
| `boottime_request` | Boot epoch time |

## Build and Run

### Prerequisites

```sh
# Install dependencies
apt install xorriso qemu-system-x86

# Install Limine
git clone https://github.com/limine-bootloader/limine --branch=v8.x-binary --depth=1
cp limine/limine-bios-cd.bin    iso_root/boot/limine/
cp limine/limine-uefi-cd.bin    iso_root/boot/limine/
cp limine/limine-bios.sys       iso_root/boot/limine/
```

### Build the kernel ELF

```sh
zig build
# Output: zig-out/bin/magicore
```

### Build the bootable ISO

```sh
zig build iso
# Output: magicore.iso
```

### Run in QEMU (no KVM)

```sh
zig build run
# Serial output appears in your terminal
# Expected output:
#
#   ███╗   ███╗ █████╗  ██████╗ ██╗...
#   Magicore v0.1.0 — No C. No spaghetti. No 40-year debt.
#
#   [boot] kernel phys=0x0000000001000000 virt=0xFFFFFFFF80000000
#   [boot] HHDM offset=0xFFFF800000000000
#   [boot] memory map entries: 7
#   [mmap] 0x000000000000–0x00000009F000  USABLE
#   ...
#   [boot] usable RAM: 65536 pages (256 MiB)
#   [arch] GDT loaded
#   [arch] IDT loaded
#   [arch] CPU features OK
#   Magicore kernel ready.
```

### Run in QEMU with KVM (Linux host)

```sh
zig build run-kvm
```

## What Limine Gives Us

- Long mode (64-bit) already active
- Stack already valid (16KB minimum)
- Higher-half mapped: kernel at `0xFFFFFFFF80000000+`
- Physical memory direct-mapped via HHDM offset
- No real-mode code, no A20 gate, no GDT dance before Zig runs

This lets us write clean Zig from the very first instruction
without any assembly preamble beyond what Limine already handled.

## Serial Output

COM1 (0x3F8) at 115200 baud, 8N1, no flow control.

Connect via:
```sh
# QEMU: -serial stdio   (default in zig build run)
# Physical hardware: any 3.3V USB-serial adapter
# Virtual machine: Connect to COM1
```

## Panic Output

A kernel panic prints:
```
╔══════════════════════════════════════════╗
║     MAGICORE KERNEL PANIC                ║
╚══════════════════════════════════════════╝
<reason>
```
...then halts all CPUs via `cli; hlt` loop.
The panic path never allocates — it writes directly to UART.
