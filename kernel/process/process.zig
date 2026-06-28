//! Magicore process model.
//!
//! A Process owns:
//!   - A unique PID
//!   - An AddressSpace (page tables + VMA list)
//!   - A file descriptor table
//!   - A signal mask
//!   - Parent PID + child list
//!
//! Processes are reference-counted via the process table.
//! fork() copies the parent's VMA list and page tables.
//! exec() replaces the current process's address space.
//! exit() marks the process zombie; wait() reaps it.
//!
//! This is the minimal process model needed for a first userspace process.
//! No threads yet (that's Phase 2). Each process has exactly one execution context.

const std     = @import("std");
const mm      = @import("../mm/mm.zig");
const vmm     = @import("../mm/vmm.zig");
const sched   = @import("../sched/sched.zig");
const console = @import("../../lib/console.zig");

pub const Pid = u32;
pub const MAX_PID: Pid  = 65535;
pub const MAX_FDS: usize = 64;

// ----------------------------------------------------------------
// File descriptor table
// ----------------------------------------------------------------

/// A minimal file descriptor entry
pub const Fd = struct {
    open:   bool  = false,
    offset: u64   = 0,
    flags:  u32   = 0,
    // TODO: pointer to VFS node
};

// ----------------------------------------------------------------
// Process control block
// ----------------------------------------------------------------

pub const ProcessState = enum {
    running,
    blocked,
    zombie,   // exited, waiting to be reaped
};

pub const Process = struct {
    pid:        Pid,
    ppid:       Pid,          // parent PID
    state:      ProcessState,
    exit_code:  i32,
    as:         vmm.AddressSpace,
    fds:        [MAX_FDS]Fd,
    /// Kernel stack base (physical) — for context switch
    kstack:     mm.PhysAddr,
    /// Saved register state (used on context switch)
    rsp:        u64,
    rip:        u64,

    pub fn deinit(self: *Process) void {
        self.as.deinit();
        if (self.kstack != 0) mm.freePage(self.kstack);
    }
};

// ----------------------------------------------------------------
// Process table
// ----------------------------------------------------------------

/// Global process table — flat array, indexed by PID
/// MAX_PID slots; slot 0 reserved (invalid), slot 1 = init.
var ptable: [MAX_PID + 1]?*Process = [_]?*Process{null} ** (MAX_PID + 1);
var next_pid: Pid = 1;
/// Current running process (null in early boot)
pub var current: ?*Process = null;

pub fn init() void {
    // ptable is static; no dynamic init needed
    console.print("[proc] process table ready (max {} processes)\n", .{MAX_PID});
}

// ----------------------------------------------------------------
// PID allocation
// ----------------------------------------------------------------

fn allocPid() error{PidExhausted}!Pid {
    var tries: usize = 0;
    while (tries < MAX_PID) : (tries += 1) {
        const pid = next_pid;
        next_pid = if (pid >= MAX_PID) 1 else pid + 1;
        if (ptable[pid] == null) return pid;
    }
    return error.PidExhausted;
}

// ----------------------------------------------------------------
// Process allocation
// ----------------------------------------------------------------

/// Allocate a new Process struct from the kernel heap.
fn allocProcess(pid: Pid, ppid: Pid) error{OutOfMemory}!*Process {
    const proc = try mm.kernel_allocator.create(Process);
    const kstack = try mm.buddy_alloc.alloc(0); // 4KB kernel stack per process
    proc.* = .{
        .pid       = pid,
        .ppid      = ppid,
        .state     = .running,
        .exit_code = 0,
        .as        = try vmm.AddressSpace.init(mm.kernel_allocator, mm.buddy_alloc.hhdm_offset),
        .fds       = [_]Fd{.{}} ** MAX_FDS,
        .kstack    = kstack,
        .rsp       = 0,
        .rip       = 0,
    };
    return proc;
}

// ----------------------------------------------------------------
// Syscall implementations
// ----------------------------------------------------------------

/// sys_fork: create a child process that is a copy of the current process.
/// Returns child PID in parent, 0 in child.
/// For now: child gets a fresh AddressSpace (full COW is Phase 2).
pub fn sys_fork() u64 {
    const parent = current orelse return @bitCast(@as(i64, -1)); // ESRCH

    const pid = allocPid() catch return @bitCast(@as(i64, -12)); // ENOMEM
    const child = allocProcess(pid, parent.pid) catch return @bitCast(@as(i64, -12));

    // Copy parent VMA list into child (regions only; physical pages on-fault)
    for (parent.as.regions.items) |region| {
        child.as.mapRegion(region) catch {
            child.deinit();
            mm.kernel_allocator.destroy(child);
            return @bitCast(@as(i64, -12));
        };
    }

    // Inherit open file descriptors
    child.fds = parent.fds;

    ptable[pid] = child;

    // Enqueue child task into scheduler
    const task = sched.Task.new(pid, .interactive);
    // We can't easily enqueue here without the RunQueue ref — scheduler
    // will pick up newly-registered PIDs. (Full context switch in Phase 2.)
    _ = task;

    console.print("[proc] fork: pid={} -> child={} \n", .{ parent.pid, pid });
    return pid; // parent receives child PID
}

/// sys_exit: terminate the current process with an exit code.
pub fn sys_exit(code: u64) u64 {
    const proc = current orelse return @bitCast(@as(i64, -1));
    proc.state     = .zombie;
    proc.exit_code = @intCast(code & 0xFF);
    console.print("[proc] exit: pid={} code={}\n", .{ proc.pid, proc.exit_code });
    // TODO: wake parent if blocked in wait()
    // TODO: call sched.yield() to switch to next task
    return 0;
}

/// sys_wait: block until any child exits, return its PID and exit code.
/// args[0] = pointer to i32 status (user address).
pub fn sys_wait(_status_ptr: u64) u64 {
    const parent = current orelse return @bitCast(@as(i64, -1));
    // Scan for zombie children
    for (ptable[1..]) |maybe_child| {
        const child = maybe_child orelse continue;
        if (child.ppid != parent.pid) continue;
        if (child.state != .zombie) continue;
        const cpid = child.pid;
        // Reap: free process resources
        child.deinit();
        mm.kernel_allocator.destroy(child);
        ptable[cpid] = null;
        console.print("[proc] wait: reaped pid={}\n", .{cpid});
        return cpid;
    }
    // No zombie children found — would block; return ECHILD for now
    return @bitCast(@as(i64, -10)); // ECHILD
}

/// sys_getpid: return PID of current process.
pub fn sys_getpid() u64 {
    const proc = current orelse return 0;
    return proc.pid;
}

/// sys_exec: replace the current process image with a new ELF binary.
/// args[0] = user pointer to ELF bytes, args[1] = length.
/// Delegates to elf.zig loader.
pub fn sys_exec(elf_ptr: u64, elf_len: u64) u64 {
    const proc = current orelse return @bitCast(@as(i64, -1));
    const elf_bytes: []const u8 = blk: {
        // Validate user pointer is in a readable region
        const region = proc.as.find(elf_ptr) orelse return @bitCast(@as(i64, -14)); // EFAULT
        if (!region.prot.read) return @bitCast(@as(i64, -14));
        const ptr: [*]const u8 = @ptrFromInt(mm.physToVirt(
            proc.as.translate(elf_ptr) orelse return @bitCast(@as(i64, -14))
        ));
        break :blk ptr[0..elf_len];
    };
    const entry = @import("elf.zig").load(&proc.as, elf_bytes) catch |err| {
        console.print("[proc] exec failed: {}\n", .{err});
        return @bitCast(@as(i64, -8)); // ENOEXEC
    };
    // Set new entry point
    proc.rip = entry;
    console.print("[proc] exec: pid={} entry=0x{X:0>16}\n", .{ proc.pid, entry });
    return 0;
}

// ----------------------------------------------------------------
// Tests
// ----------------------------------------------------------------

test "Pid arithmetic does not wrap below 1" {
    // next_pid starts at 1; after MAX_PID it wraps to 1, not 0
    var pid: Pid = MAX_PID;
    pid = if (pid >= MAX_PID) 1 else pid + 1;
    try std.testing.expectEqual(pid, 1);
}

test "ProcessState transitions" {
    var s: ProcessState = .running;
    s = .zombie;
    try std.testing.expectEqual(s, .zombie);
}

test "Fd default is closed" {
    const fd = Fd{};
    try std.testing.expect(!fd.open);
    try std.testing.expectEqual(fd.offset, 0);
}
