# Magicore Architecture

## Overview

Magicore is a hybrid monolithic kernel with strict subsystem contracts.
It combines the performance of a monolithic design with the boundary discipline of a microkernel.

## Layer Model

```
┌─────────────────────────────────────┐
│           Userspace                 │
│  (processes, daemons, apps)         │
├─────────────────────────────────────┤
│         Syscall Interface           │  ← only legal user→kernel boundary
├─────────────────────────────────────┤
│         Service Layer               │
│  VFS │ Sockets │ Security │ Devices │
├─────────────────────────────────────┤
│           Core Layer                │
│  Scheduler │ MM │ IPC │ Timers      │
├─────────────────────────────────────┤
│           Arch Layer                │
│  x86_64 │ arm64 (planned)           │
└─────────────────────────────────────┘
```

## Design Principles

### 1. No hidden control flow
All subsystem interactions go through explicit function calls or vtable dispatch.
No implicit hooks, no notifier chains that can deadlock.

### 2. Explicit allocation
Every allocation names its allocator. No hidden heap use.
Kernel subsystems use a per-subsystem arena or slab allocator.

### 3. Error handling is mandatory
All fallible functions return error unions.
No `void` return from functions that can fail.
No errno. No global error state.

### 4. Comptime over runtime
Configuration, dispatch tables, and capability checks are resolved at comptime
wherever possible. Runtime overhead is minimized.

### 5. Driver isolation
Drivers are modules with typed vtable interfaces.
A misbehaving driver cannot corrupt kernel state — it can only return an error.

### 6. Capability-based security
No ambient authority. Every process has an explicit CapSet.
No setuid, no sudo, no ambient root.

## Subsystem Dependency Order

```
arch → mm → sched → ipc → vfs → net → security → drivers → syscall
```

No subsystem may depend on a subsystem to its right in this chain.
Circular dependencies are a build error.

## Scheduler Design

Magicore's scheduler introduces a first-class `LatencyClass`:

| Class | Use case | Policy |
|---|---|---|
| `realtime` | Audio, sensors | Fixed priority, preempt immediately |
| `interactive` | UI, shell | Low vruntime target, fast wakeup |
| `inference` | AI model forward pass | NUMA-aware, large time slice, memory pinned |
| `batch` | Compilation, indexing | CFS vruntime, can be preempted freely |

The `inference` class is a first-class citizen — not an afterthought bolted on top.

## IPC Model

All IPC is message-passing via typed `Channel(T, capacity)`.
No shared memory IPC by default — sharing requires explicit capability.
Channels are bounded — backpressure is built in.

## Memory Model

- Physical memory: buddy allocator over free regions from boot memory map
- Kernel heap: slab allocator per object size class
- Per-process VAS: page table per process, no shared mutable page tables
- Huge pages: explicit opt-in, not transparent

## Security Model

Capability-based. Capabilities are:
- Unforgeable (not integers passed over syscall — kernel-managed tokens)
- Non-ambient (no implicit authority from being root)
- Composable (intersection/union ops on CapSet)
- AI-aware (`ml_infer`, `ml_train` are first-class capabilities)
