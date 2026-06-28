# Magicore Update Log

## [0.1.7] — 2026-06-28

### Context switch, TSS RSP0, APIC tick preemption, IRETQ to userspace

**Files changed:**
- `arch/x86_64/context.zig` — new: `KernelContext`, `IretFrame`, `Tss`, `loadTss`, `setRsp0`, naked `switchTo`, `taskEntryTrampoline`, `buildKernelStack`
- `kernel/sched/sched.zig` — rewrite: `Task` gains `saved_rsp`/`kstack_top`/`slice_ticks`/`pid`; real `tick()` decrements slice + re-enqueues + calls `schedule()`; `schedule()` calls `ctx.switchTo`; `registerTask()` added; `start()` enables interrupts + HLT loop
- `arch/x86_64/apic.zig` — `apicTimerHandler` wired: calls `sched.tick()` + EOI; IDT 0x20 live
- `arch/x86_64/init.zig` — GDT extended with TSS descriptor (0x28/0x30); `ctx.loadTss()` called; `idt_setup()` installs #PF (14) and APIC timer (0x20)

**What this unlocks:**
- Full preemptive multitasking: APIC fires every 1ms, tick decrements slice, schedule() picks next, switchTo saves/restores callee-saved regs + RSP, IRETQ jumps to userspace
- `userspace/init/init.zig` (PID 1) will now actually run under real CPU scheduling
- TSS.RSP0 updated on every switch so syscalls and interrupts from userspace land on the correct kernel stack
- Time slice budgets: realtime=1ms, interactive=5ms, inference=50ms, batch=20ms

---

## [0.1.6] — 2026-06-28

### VFS mount table, stdout/stderr, open/close/read/write/stat, init PID 1

**Files changed:**
- `kernel/fs/vfs_mount.zig` — new: mount table, stdout/stderr UART-backed special files, RamFs VFS adapter
- `kernel/process/process.zig` — Fd struct now holds `vfs.File`; added `sys_open`, `sys_close`, `sys_read`, `sys_write`, `sys_stat`; stdio (fd 0/1/2) wired at process creation
- `kernel/syscall/table.zig` — open/close/read/write/stat wrappers wired
- `kernel/main.zig` — `vfs_mnt.init()` added to boot sequence between APIC and proc
- `userspace/init/init.zig` — new: PID 1, writes "Hello from Magicore userspace!" via syscall, then exit(0)

---

## [0.1.5] — 2026-06-28

### SYSCALL/SYSRET MSRs, process model, fork/exec/exit/wait/getpid, ELF-64 loader

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
- `kernel/mm/buddy.zig` — full addRegion, alloc (split-down), free (XOR coalesce)
- `kernel/mm/mm.zig` — wired to Limine memmap + HHDM offset; KernelAllocator bridge
- `kernel/sched/sched.zig` — RunQueue uses kernel_allocator
- `kernel/main.zig` — hhdm_offset threaded through to mm.init

---

## [0.1.2] — 2026-06-28

### Boot bring-up: Limine v8 protocol, 16550 UART, GDT/IDT, QEMU run target

**Files changed:**
- `drivers/uart16550.zig`, `arch/x86_64/limine.zig`, `arch/x86_64/boot.zig`
- `arch/x86_64/init.zig`, `arch/x86_64/linker.ld`
- `lib/console.zig`, `build.zig`, `misc/limine.conf`, `docs/boot.md`

---

## [0.1.1] — 2026-06-28

### Foundation: kernel architecture stubs

**Files changed:**
- `kernel/mm/`, `kernel/sched/`, `kernel/io/ring.zig`, `kernel/net/tcp.zig`
- `kernel/fs/ramfs.zig`, `kernel/security/`, `security/caps.zig`
- `docs/superiority.md`

---

## [0.1.0] — 2026-06-28

### Initial commit: repository scaffold

- `src/types.zig`, `build.zig`, `README.md`, `docs/roadmap.md`
