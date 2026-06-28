# Magicore Roadmap

## Phase 0: Foundation
✅ Complete

- [x] Repository scaffold
- [x] Architecture specification and coding rules
- [x] Build system (build.zig: build/iso/run/run-kvm/test)
- [x] Core type definitions: mm, sched, ipc, syscall, vfs, net, security
- [x] Lock-free slab allocator, O(1) priority scheduler
- [x] Zero-copy I/O ring, TCP state machine, ramfs
- [x] Capability model, KASLR, entropy, syscall gate, verified boot

## Phase 1: Boot Bring-up
🔶 In Progress

- [x] Limine v8 protocol — all 6 request types
- [x] 16550 UART driver (COM1, 115200 8N1)
- [x] Boot stub: banner, memory map dump, BootInfo construction
- [x] Real GDT (5 entries) + IDT (32 exception stubs) with CPUID checks
- [x] Buddy allocator: real addRegion, alloc, free, coalesce
- [x] mm::init wired to Limine memory map + HHDM offset
- [x] std.mem.Allocator bridge (KernelAllocator) over buddy
- [x] kmain wired: arch → mm → sched → ipc → syscall → sched.start()
- [ ] Page table init (PML4 → PDPT → PD → PT)
- [ ] Page fault handler
- [ ] APIC timer init + tick() wired
- [ ] SYSCALL/SYSRET MSR setup

## Phase 2: Core OS

- [ ] Processes: fork, exec, exit, wait
- [ ] Virtual memory per process (AddressSpace)
- [ ] ELF userspace loader
- [ ] Per-CPU run queues (SMP)
- [ ] IPC channels: typed, bounded, tested
- [ ] Pipes and file descriptors
- [ ] ramfs mount as root filesystem

## Phase 3: Hardware and I/O

- [ ] virtio-blk (QEMU block device)
- [ ] virtio-net (QEMU networking)
- [ ] virtio-gpu (QEMU display)
- [ ] PCIe host bridge enumeration
- [ ] NVMe driver (real hardware)
- [ ] USB XHCI (keyboard/mouse)
- [ ] ACPI power management

## Phase 4: Filesystems and Networking

- [ ] ext4 read support
- [ ] TCP/IP stack (on top of tcp.zig state machine)
- [ ] Unix domain sockets
- [ ] DNS resolver stub
- [ ] TLS (pure Zig, no OpenSSL)

## Phase 5: Linux Compatibility

- [ ] Linux syscall ABI compatibility layer
- [ ] musl libc support
- [ ] Basic shell (dash or busybox)
- [ ] Container support (namespaces, cgroups equivalent)

## Phase 6: AI Integration

- [ ] NUMA-aware scheduler
- [ ] Huge page support
- [ ] GPU compute scheduling (inference)
- [ ] Model runtime service in userspace
- [ ] Inference-optimized memory allocator
- [ ] Power management: tickless idle, frequency scaling

## Phase 7: Security Hardening

- [ ] Formal capability model audit
- [ ] Syscall filtering (seccomp equivalent)
- [ ] KASLR entropy audit
- [ ] CFI (control flow integrity)
- [ ] Verified boot integration with TPM

## Metrics vs Linux 7.1

| Metric | Linux 7.1 | Magicore target |
|---|---|---|
| Boot to shell | ~1.5s | < 0.5s |
| Kernel CVEs/year | 200+ | < 10 |
| Syscall surface | 350+ | < 70 |
| Kernel binary size | ~10MB | < 2MB |
| Scheduler pick-next | O(log N) | O(1) |
| Inference latency | baseline | -30% |
| Context switch (ns) | ~1000ns | < 300ns |
| Idle memory footprint | ~50MB | < 10MB |
