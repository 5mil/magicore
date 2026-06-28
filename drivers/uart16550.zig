//! Magicore 16550 UART driver.
//! COM1: I/O base 0x3F8, IRQ4.
//! COM2: I/O base 0x2F8, IRQ3.
//! Fully freestanding — zero allocations, zero dependencies.
//! Used as the primary early console before framebuffer init.
//!
//! Register map (offset from base):
//!   0: RBR/THR  (read = recv, write = transmit)
//!   1: IER      (interrupt enable)
//!   2: IIR/FCR  (interrupt ident / FIFO control)
//!   3: LCR      (line control)
//!   4: MCR      (modem control)
//!   5: LSR      (line status)
//!   6: MSR      (modem status)

const std = @import("std");

pub const COM1: u16 = 0x3F8;
pub const COM2: u16 = 0x2F8;

/// UART register offsets
const REG_DATA:  u16 = 0; // RBR (read) / THR (write)
const REG_IER:   u16 = 1; // Interrupt Enable
const REG_FCR:   u16 = 2; // FIFO Control
const REG_LCR:   u16 = 3; // Line Control
const REG_MCR:   u16 = 4; // Modem Control
const REG_LSR:   u16 = 5; // Line Status
// DLAB (LCR bit 7 set) remaps offsets 0..1 to divisor latch
const REG_DLL:   u16 = 0; // Divisor Latch Low  (DLAB=1)
const REG_DLH:   u16 = 1; // Divisor Latch High (DLAB=1)

/// Line Status Register bits
const LSR_DATA_READY:   u8 = 0x01; // data available to read
const LSR_THR_EMPTY:    u8 = 0x20; // transmit holding register empty

/// UART instance
pub const Uart = struct {
    base: u16,
    initialized: bool,

    pub fn init(base: u16, baud: u32) Uart {
        // Baud rate divisor: 115200 / baud
        const divisor: u16 = @intCast(115200 / baud);

        // Disable interrupts
        outb(base + REG_IER, 0x00);

        // Enable DLAB to set baud rate divisor
        outb(base + REG_LCR, 0x80);
        outb(base + REG_DLL, @truncate(divisor & 0xFF));
        outb(base + REG_DLH, @truncate((divisor >> 8) & 0xFF));

        // 8 bits, no parity, 1 stop bit (8N1), disable DLAB
        outb(base + REG_LCR, 0x03);

        // Enable and clear FIFO, 14-byte threshold
        outb(base + REG_FCR, 0xC7);

        // IRQs enabled, RTS/DSR set
        outb(base + REG_MCR, 0x0B);

        return .{ .base = base, .initialized = true };
    }

    /// Write a single byte — spins until THR empty
    pub fn writeByte(self: Uart, byte: u8) void {
        // Wait for transmit holding register to be empty
        while ((inb(self.base + REG_LSR) & LSR_THR_EMPTY) == 0) {
            asm volatile ("pause");
        }
        outb(self.base + REG_DATA, byte);
    }

    /// Write a string slice
    pub fn writeStr(self: Uart, s: []const u8) void {
        for (s) |c| {
            // Translate \n → \r\n for serial terminals
            if (c == '\n') self.writeByte('\r');
            self.writeByte(c);
        }
    }

    /// Write formatted output (comptime fmt)
    pub fn print(self: Uart, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch "<fmt overflow>";
        self.writeStr(s);
    }

    /// Read one byte (blocks until available)
    pub fn readByte(self: Uart) u8 {
        while ((inb(self.base + REG_LSR) & LSR_DATA_READY) == 0) {
            asm volatile ("pause");
        }
        return inb(self.base + REG_DATA);
    }

    /// Non-blocking read — returns null if no data
    pub fn tryReadByte(self: Uart) ?u8 {
        if ((inb(self.base + REG_LSR) & LSR_DATA_READY) == 0) return null;
        return inb(self.base + REG_DATA);
    }
};

/// x86 I/O port write
inline fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "N{dx}" (port)
    );
}

/// x86 I/O port read
inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[val]"
        : [val] "={al}" (-> u8)
        : [port] "N{dx}" (port)
    );
}

/// Global kernel UART (COM1, 115200 8N1)
/// Initialized in boot before kmain.
pub var kernel_uart: Uart = undefined;
pub var kernel_uart_ready: bool = false;

pub fn initKernelUart() void {
    kernel_uart = Uart.init(COM1, 115200);
    kernel_uart_ready = true;
}

test "Uart divisor math" {
    // 115200 baud divisor = 1
    const divisor: u16 = @intCast(115200 / 115200);
    try std.testing.expectEqual(divisor, 1);
    // 9600 baud divisor = 12
    const d2: u16 = @intCast(115200 / 9600);
    try std.testing.expectEqual(d2, 12);
}
