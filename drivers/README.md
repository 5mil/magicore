# Magicore Drivers

All drivers in Magicore follow strict isolation rules:

## Rules

1. **Narrow interface** — drivers implement a typed vtable. No direct kernel struct access.
2. **No global mutable state** — driver state is heap-allocated and passed as a pointer.
3. **Explicit error handling** — every hardware failure surfaces as an error union. No silent ignores.
4. **Testable in isolation** — every driver has a corresponding `tests.zig` that runs on host.
5. **No ioctl** — driver-specific operations go through typed methods on the vtable, not a generic ioctl dispatch.

## Driver Categories

| Category | Status |
|---|---|
| Serial UART (16550) | 🔲 Planned |
| Framebuffer (linear) | 🔲 Planned |
| PCIe host bridge | 🔲 Planned |
| NVMe block device | 🔲 Planned |
| virtio-net | 🔲 Planned |
| virtio-blk | 🔲 Planned |
| USB XHCI | 🔲 Planned |
| Intel HDA audio | 🔲 Planned |
| ACPI/AML interpreter | 🔲 Planned |
| GPU (virtio-gpu first) | 🔲 Planned |
