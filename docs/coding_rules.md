# Magicore Coding Rules

These rules are not suggestions. They are enforced by review and — where possible — by the compiler.

## Language

1. **Zig only.** No C files in the kernel tree. No C headers except for hardware register definitions imported via `@cImport` in arch-specific code only.
2. **Zig version: 0.14.** No nightly features.
3. **No external libraries.** Stdlib only. No third-party crates/packages.

## Memory

4. **Every allocation names its allocator.** No `std.heap.page_allocator` in kernel code. Use the kernel-provided slab/arena allocators.
5. **No allocations in interrupt context.** Functions called from interrupt handlers must be allocation-free.
6. **Use `defer` for cleanup.** No manual free at end of scope without `defer`.
7. **No pointer arithmetic without bounds justification comment.**

## Errors

8. **All errors must surface.** No silent `catch {}`. The only exception is network send() where write failure is non-fatal and must be explicitly documented.
9. **No `unreachable` in production paths.** Only in `comptime` or in paths that would indicate a compiler bug.
10. **No `@panic` outside console.panic().** Panics go through the kernel panic path for proper diagnostics.

## Concurrency

11. **Document lock acquisition order.** Every lock must have a comment stating its order in the global lock order.
12. **No locks in interrupt context.** Use lock-free structures or disable interrupts explicitly with documented scope.
13. **No sleeping in interrupt context.**

## Subsystems

14. **Subsystems depend only leftward.** See architecture.md dependency order. Circular deps are a build error.
15. **Every subsystem has tests.zig.** Tests run on host (not QEMU). No I/O in unit tests.
16. **Driver interfaces are vtables.** No direct struct access across subsystem boundary.

## Style

17. **No abbreviations in public names.** `MemMapEntry` not `MmE`. `FrameAllocator` not `FA`.
18. **snake_case for variables and functions, PascalCase for types.**
19. **Comptime over runtime where correct.** If a value is known at comptime, it must be comptime.
20. **Every public function has a doc comment.**
