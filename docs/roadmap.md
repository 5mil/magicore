# Magicore Roadmap

## Phase 0: Foundation (now)

- [x] Repository scaffold
- [x] Architecture specification
- [x] Coding rules and subsystem contracts
- [x] Build system skeleton (build.zig)
- [x] Core type definitions: mm, sched, ipc, syscall, vfs, net, security
- [ ] Serial UART driver (16550)
- [ ] Limine bootloader integration
- [ ] Initial page allocator (bitmap over memory map)
- [ ] UART-based console output

## Phase 1: Bring-up

- [ ] Boot to kmain on real/QEMU x86_64 hardware
- [ ] Physical frame allocator operational
- [ ] Virtual memory and page tables
- [ ] GDT/IDT/APIC initialized
- [ ] Timer interrupt and basic tick
- [ ] Single-CPU context switch
- [ ] Kernel panic with stack trace

## Phase 2: Core OS

- [ ] Processes: fork, exec, exit, wait
- [ ] Virtual memory per process
- [ ] ELF userspace loader
- [ ] Scheduler: per-CPU runqueues, 4 latency classes
- [ ] IPC channels: typed, bounded, tested
- [ ] Pipes
- [ ] File descriptors
- [ ] ramfs (in-memory filesystem)

## Phase 3: Hardware and I/O

- [ ] virtio-blk (block device for QEMU)
- [ ] virtio-net (network for QEMU)
- [ ] virtio-gpu (display for QEMU)
- [ ] PCIe host bridge enumeration
- [ ] NVMe driver (real hardware)
- [ ] USB XHCI (keyboard/mouse)
- [ ] ACPI power management

## Phase 4: Filesystems and Networking

- [ ] ext4 read support
- [ ] TCP/IP stack
- [ ] Unix domain sockets
- [ ] DNS resolver stub
- [ ] TLS library (pure Zig, no OpenSSL)

## Phase 5: Linux Compatibility

- [ ] Linux syscall ABI compatibility layer
- [ ] musl libc support
- [ ] Basic shell (dash or busybox)
- [ ] Container support (namespaces, cgroups equivalent)

## Phase 6: Performance and AI Integration

- [ ] NUMA-aware scheduler
- [ ] Huge page support
- [ ] GPU compute support (inference scheduling)
- [ ] Model runtime service in userspace
- [ ] Inference-optimized memory allocator
- [ ] Power management: tickless idle, frequency scaling

## Phase 7: Security Hardening

- [ ] Formal capability model audit
- [ ] Syscall filtering (seccomp equivalent)
- [ ] Kernel address space layout randomization (KASLR)
- [ ] CFI (control flow integrity)
- [ ] Verified boot integration

## Target metrics vs Linux 7.1

| Metric | Linux 7.1 | Magicore target |
|---|---|---|
| Boot to shell | ~1.5s | < 0.5s |
| Kernel CVEs/year | 200+ | < 10 |
| Syscall surface | 350+ | < 70 |
| Kernel binary size | ~10MB | < 2MB |
| Inference task latency | baseline | -30% |
| Context switch (ns) | ~1000ns | < 300ns |
| Idle memory footprint | ~50MB | < 10MB |
