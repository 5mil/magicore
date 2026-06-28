# Magicore

> A new operating system kernel, written entirely in Zig.
> Built from first principles. No C. No spaghetti. No 40-year debt.

---

## What Magicore Is

Magicore is a **new kernel** for a new operating system.
It is not a Linux port, not a Linux fork, not a compatibility shim.
It is a clean-slate kernel written in [Zig 0.14](https://ziglang.org),
designed around the lessons of 40 years of OS development — without inheriting any of the baggage.

Magicore is the kernel layer of **Zigllm-os**: an AI-native, developer-first operating system.

---

## Quick Start

```sh
# Dependencies
apt install xorriso qemu-system-x86 zig

# Clone
git clone https://github.com/5mil/magicore && cd magicore

# Build kernel ELF
zig build

# Build bootable ISO  (requires Limine — see docs/boot.md)
zig build iso

# Boot in QEMU — serial output to terminal
zig build run

# Run all unit tests on host
zig build test
```

---

## Repository Layout

```
magicore/
  arch/x86_64/        # Boot stub, GDT, IDT, Limine protocol, linker script
  drivers/            # UART 16550, (PCIe, NVMe, virtio planned)
  kernel/
    mm/               # Buddy allocator, slab, VMM, page tables
    sched/            # O(1) priority scheduler, latency classes
    ipc/              # Typed bounded message channels
    syscall/          # Syscall table (30 calls, all typed)
    io/               # Zero-copy I/O ring
    net/              # TCP state machine
    fs/               # ramfs
    security/         # Entropy, KASLR, syscall gate, verified boot
  fs/                 # VFS vtable interface
  net/                # Socket vtable interface
  security/           # Capability-based security (CapSet)
  lib/                # Kernel console (UART-backed, no alloc)
  misc/               # limine.conf
  docs/               # Architecture, roadmap, boot, superiority analysis
  build.zig           # zig build | iso | run | run-kvm | test
```

---

## Why Zig

- No hidden control flow
- No implicit memory allocation
- Explicit error handling — compiler enforces it
- `defer`/`errdefer` make cleanup correct by construction
- `comptime` eliminates runtime bug classes at compile time
- No undefined behavior by default
- No C preprocessor macro hell
- One `build.zig` replaces Kbuild + Kconfig + Make

---

## Design Goals

| Goal | How |
|---|---|
| Memory safety | Zig ownership + no hidden allocations |
| Crash resistance | Typed error unions, no silent failures |
| Performance | O(1) scheduler, lock-free allocator hot path |
| Auditability | Every subsystem independently testable on host |
| Security | Mandatory cap gate, KASLR, verified boot chain |
| AI-native | `inference` latency class + `ml_infer` capability |
| Clean architecture | Comptime vtables, strict subsystem boundaries |

---

## Magicore vs Linux 7.2

| Metric | Linux 7.2 | Magicore target |
|---|---|---|
| Boot to shell | ~1.5s | < 0.5s |
| CVEs/year | 200+ | < 10 |
| Syscall surface | 350+ | 30 |
| Kernel binary size | ~10MB | < 2MB |
| Scheduler pick-next | O(log N) | **O(1)** |
| Inference task latency | baseline | -30% |
| Context switch | ~1000ns | < 300ns |
| Idle memory footprint | ~50MB | < 10MB |
| Language | C (1972) | Zig 0.14 |

See [docs/superiority.md](docs/superiority.md) for the full technical breakdown.

---

## Status

| Phase | Status |
|---|---|
| 0 — Foundation | ✅ Complete |
| 1 — Boot bring-up | 🔶 In progress |
| 2 — Core OS | 🔲 Planned |
| 3 — Hardware & I/O | 🔲 Planned |
| 4 — Filesystems & Net | 🔲 Planned |
| 5 — Linux Compatibility | 🔲 Planned |
| 6 — AI Integration | 🔲 Planned |
| 7 — Security Hardening | 🔲 Planned |

See [docs/roadmap.md](docs/roadmap.md) for the full phased plan.

---

## License

MIT — see [LICENSE](LICENSE)
