# Magicore Update Log

## [0.1.6] — 2026-06-28

### VFS mount table, stdout/stderr, open/close/read/write/stat, init PID 1

**Files changed:**
- `kernel/fs/vfs_mount.zig` — new: mount table, stdout/stderr UART-backed special files, RamFs VFS adapter
- `kernel/process/process.zig` — Fd struct now holds `vfs.File`; added `sys_open`, `sys_close`, `sys_read`, `sys_write`, `sys_stat`; stdio (fd 0/1/2) wired at process creation
- `kernel/syscall/table.zig` — open/close/read/write/stat wrappers wired
- `kernel/main.zig` — `vfs_mnt.init()` added to boot sequence between APIC and proc
- `userspace/init/init.zig` — new: PID 1, writes "Hello from Magicore userspace!" via syscall, then exit(0)

**What this unlocks:**
- First complete end-to-end userspace path: `exec` ELF → `write(1, msg, n)` → UART output
- `fd 0/1/2` (stdin/stdout/stderr) live in every process at birth
- Any file in the root ramfs is openable/readable/writable from userspace
- Foundation for shell, init system, and daemon launch

---

## [0.1.5] — 2026-06-28

### SYSCALL/SYSRET, process model, fork/exec/exit/wait/getpid, ELF-64 loader

**Files changed:**
- `arch/x86_64/syscall.zig` — new: STAR/LSTAR/FMASK/EFER MSR setup, naked SYSCALL entry, Zig dispatcher
- `kernel/process/process.zig` — new: full process table (65535 slots), fork/exit/wait/getpid/exec
- `kernel/process/elf.zig` — new: ELF-64 loader, PT_LOAD segments, eager page mapping, BSS zero
- `kernel/syscall/table.zig` — wired to process handlers
- `arch/x86_64/init.zig` — SYSCALL CPUID check + `sc.init()` call added
- `kernel/main.zig` — `proc_mod.init()` added

---

## [0.1.4] — 2026-06-28

### x86_64 page tables, page fault handler, VMM drives hardware PT, APIC timer

**Files changed:**
- `kernel/mm/pgtable.zig` — new: PML4→PDPT→PD→PT mapPage/unmapPage/translate/loadCr3/initKernelPt
- `kernel/mm/vmm.zig` — rewrite: drives pgtable, sorted VMAs, real handleFault with frame alloc+zero
- `arch/x86_64/pagefault.zig` — new: IDT #PF handler, CR2 read, user/kernel fault dispatch
- `arch/x86_64/apic.zig` — new: LAPIC init, 8259 PIC disable, PIT-calibrated 1ms periodic timer
- `kernel/main.zig` — pgtable.initKernelPt + loadCr3 + apic.init added

---

## [0.1.3] — 2026-06-28

### Physical memory manager: real buddy allocator + std.mem.Allocator bridge

**Files changed:**
- `kernel/mm/buddy.zig` — full addRegion (greedy order-fit), alloc (split-down), free (XOR coalesce); intrusive FreeNode in free pages
- `kernel/mm/mm.zig` — wired to Limine memmap + HHDM offset; KernelAllocator bridge; buddy smoke-test
- `kernel/sched/sched.zig` — RunQueue uses kernel_allocator
- `kernel/main.zig` — hhdm_offset threaded through to mm.init

**Tests added:** addRegion, alloc order-0, alloc+free coalesce, order-2, OOM, utilization, RunQueue O(1), Task priority

---

## [0.1.2] — 2026-06-28

### Boot bring-up: Limine v8 protocol, 16550 UART, real boot stub, GDT/IDT, QEMU run target

**Files changed:**
- `drivers/uart16550.zig` — new: COM1 init, writeByte/writeStr/print/readByte/tryReadByte
- `arch/x86_64/limine.zig` — new: all 6 Limine v8 request/response types in .requests section
- `arch/x86_64/boot.zig` — rewrite: banner, memmap dump, BootInfo construction, kmain handoff
- `arch/x86_64/init.zig` — real GDT (5 entries), IDT (32 stubs), CPUID SSE2+NX checks
- `arch/x86_64/linker.ld` — .requests section added, KERNEL_VIRT_BASE set
- `lib/console.zig` — new: two-phase UART-backed console, panic banner
- `build.zig` — rewrite: iso/run/run-kvm/test targets; 22-file test suite
- `misc/limine.conf` — new
- `docs/boot.md` — new: full boot documentation

---

## [0.1.1] — 2026-06-28

### Foundation: kernel architecture, superiority analysis

**Files changed:**
- `kernel/mm/` — buddy, slab, VMM stubs
- `kernel/sched/` — O(1) bitmap scheduler, latency classes
- `kernel/io/ring.zig` — typed I/O ring (zero opcode confusion)
- `kernel/net/tcp.zig` — RFC 793 TCP state machine
- `kernel/fs/ramfs.zig` — in-memory filesystem
- `kernel/security/` — entropy, KASLR, syscall gate, verified boot
- `security/caps.zig` — capability model
- `docs/superiority.md` — Magicore vs Linux 7.2 technical comparison

---

## [0.1.0] — 2026-06-28

### Initial commit: repository scaffold

- `src/types.zig`, `build.zig`, `README.md`, `docs/roadmap.md`
- Zig 0.14 freestanding x86_64 target
- Module map established
