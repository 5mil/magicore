# Magicore

> A new operating system kernel, written entirely in Zig.
> Built from first principles. No C. No spaghetti. No 40-year debt.

---

## What Magicore Is

Magicore is a **new kernel** for a new operating system. It is not a Linux port, not a Linux fork, and not a compatibility shim. It is a clean-slate kernel written in [Zig](https://ziglang.org), designed around the lessons of 40 years of OS development — without inheriting any of the baggage.

Magicore is the kernel layer of **Zigllm-os**: an AI-native, developer-first operating system.

---

## Why Zig

- No hidden control flow
- No implicit memory allocation
- Explicit error handling — no silent failures
- `defer`/`errdefer` make cleanup paths correct by construction
- `comptime` replaces entire classes of runtime bugs with compile-time guarantees
- No undefined behavior by default
- No C preprocessor macro hell
- Interoperates with C ABI when needed — but we choose when

---

## Design Goals

| Goal | How |
|---|---|
| Memory safety | Zig ownership + no hidden allocations |
| Crash resistance | Structured errors, no silent swallows |
| Performance | Zero-cost abstractions, no GC, no runtime |
| Auditability | Every subsystem independently testable |
| Security | Minimal syscall surface, strict driver isolation |
| AI-native | Scheduler and memory model tuned for inference workloads |
| Clean architecture | Strict subsystem boundaries, comptime vtables |

---

## Non-Goals

- Drop-in Linux replacement (day one)
- Support every driver ever written
- Binary compatibility with everything
- Matching Linux breadth before matching Linux correctness

---

## Repository Layout

```
magicore/
  kernel/          # Core kernel: boot, sched, mm, ipc, syscall
  arch/            # Architecture-specific: x86_64 first, arm64 next
  drivers/         # Isolated driver modules with strict interfaces
  fs/              # Virtual filesystem + initial filesystems
  net/             # Networking stack
  security/        # Capability model, policy enforcement
  ipc/             # Inter-process communication primitives
  lib/             # Kernel-internal utilities (no stdlib dependency)
  build.zig        # Zig build system
  docs/            # Architecture, roadmap, subsystem specs
  tests/           # Per-subsystem unit and integration tests
```

---

## Status

🚧 **Phase 0: Foundation** — Architecture spec, coding rules, subsystem contracts.

See [docs/roadmap.md](docs/roadmap.md) for full phased plan.

---

## License

MIT — see [LICENSE](LICENSE)
