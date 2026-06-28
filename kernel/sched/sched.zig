//! Magicore scheduler.
//! CFS-inspired, O(1) bitmap pick-next, four latency classes.
//! Context switch: arch/x86_64/context.zig switchTo().
//! Timer source: APIC 1ms tick fires IRQ via vector 0x20 → sched.tick().

const std     = @import("std");
const mm      = @import("../mm/mm.zig");
const ctx     = @import("../../arch/x86_64/context.zig");
const console = @import("../../lib/console.zig");

pub const LatencyClass = enum {
    realtime,
    interactive,
    inference,
    batch,
};

pub const TaskState = enum { runnable, running, blocked, zombie };

// Time slice budgets per class (milliseconds)
const SLICE_MS = struct {
    const realtime:    u64 = 1;
    const interactive: u64 = 5;
    const inference:   u64 = 50;
    const batch:       u64 = 20;
};

pub const Task = struct {
    id:            u64,
    state:         TaskState,
    latency_class: LatencyClass,
    vruntime:      u64,  // virtual runtime (ns)
    priority:      i8,
    cpu:           u32,
    /// Saved kernel RSP (set by switchTo on context switch)
    saved_rsp:     u64,
    /// Top of kernel stack (physical) — used for TSS.RSP0
    kstack_top:    u64,
    /// Remaining time-slice ticks (1 tick = 1ms APIC)
    slice_ticks:   u64,
    /// PID this task belongs to (0 = idle)
    pid:           u32,

    pub fn new(id: u64, class: LatencyClass) Task {
        return .{
            .id            = id,
            .state         = .runnable,
            .latency_class = class,
            .vruntime      = 0,
            .priority      = 0,
            .cpu           = 0,
            .saved_rsp     = 0,
            .kstack_top    = 0,
            .slice_ticks   = sliceMs(class),
            .pid           = 0,
        };
    }

    pub fn basePriority(self: *const Task) u6 {
        return switch (self.latency_class) {
            .realtime    => 0,
            .interactive => 16,
            .inference   => 24,
            .batch       => 48,
        };
    }
};

fn sliceMs(class: LatencyClass) u64 {
    return switch (class) {
        .realtime    => SLICE_MS.realtime,
        .interactive => SLICE_MS.interactive,
        .inference   => SLICE_MS.inference,
        .batch       => SLICE_MS.batch,
    };
}

// ----------------------------------------------------------------
// Run queue
// ----------------------------------------------------------------

pub const RunQueue = struct {
    bitmap:    u64,
    queues:    [64]std.ArrayListUnmanaged(u64), // task IDs
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RunQueue {
        return .{
            .bitmap    = 0,
            .queues    = [_]std.ArrayListUnmanaged(u64){.{}} ** 64,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RunQueue) void {
        for (&self.queues) |*q| q.deinit(self.allocator);
    }

    pub fn enqueue(self: *RunQueue, task: *const Task) !void {
        const prio = task.basePriority();
        try self.queues[prio].append(self.allocator, task.id);
        self.bitmap |= (@as(u64, 1) << @as(u6, @intCast(prio)));
    }

    /// O(1) pick-next: lowest set bit = highest priority class
    pub fn pickNext(self: *RunQueue) ?u64 {
        if (self.bitmap == 0) return null;
        const prio: u6 = @intCast(@ctz(self.bitmap));
        const q = &self.queues[prio];
        const id = q.orderedRemove(0);
        if (q.items.len == 0) self.bitmap &= ~(@as(u64, 1) << prio);
        return id;
    }
};

// ----------------------------------------------------------------
// Task table (flat array indexed by task ID)
// ----------------------------------------------------------------

pub const MAX_TASKS: usize = 1024;
var task_table: [MAX_TASKS]?Task = [_]?Task{null} ** MAX_TASKS;
var next_task_id: u64 = 1; // 0 = idle

/// Register a task and return its ID.
/// Caller fills in saved_rsp + kstack_top after registration.
pub fn registerTask(pid: u32, class: LatencyClass) error{TooManyTasks, OutOfMemory}!u64 {
    if (next_task_id >= MAX_TASKS) return error.TooManyTasks;
    const id = next_task_id;
    next_task_id += 1;
    task_table[id] = Task.new(id, class);
    task_table[id].?.pid = pid;
    try global_rq.?.enqueue(&task_table[id].?);
    return id;
}

// ----------------------------------------------------------------
// Global scheduler state
// ----------------------------------------------------------------

var global_rq:    ?RunQueue = null;
var current_task: ?*Task    = null;
var idle_task:    Task      = undefined;

/// Saved RSP for the idle task (set by switchTo)
var idle_saved_rsp: u64 = 0;

pub fn init() error{OutOfMemory}!void {
    global_rq = RunQueue.init(mm.kernel_allocator);
    idle_task = Task.new(0, .batch);
    idle_task.pid = 0;
    // Idle task starts with current kernel RSP — set in start()
    console.print("[sched] scheduler ready (MAX_TASKS={})\n", .{MAX_TASKS});
}

// ----------------------------------------------------------------
// APIC tick handler — called from IRQ vector 0x20
// ----------------------------------------------------------------

/// Elapsed ms per tick (APIC fires every 1ms)
const TICK_MS: u64 = 1;

/// Global tick counter (ms since boot)
pub var ticks_ms: u64 = 0;

/// Called from the APIC timer IRQ handler (in apic.zig).
/// Decrements current task's time slice; triggers preemption if exhausted.
pub fn tick() void {
    ticks_ms += TICK_MS;

    const cur = current_task orelse return;
    if (cur.slice_ticks > 0) {
        cur.slice_ticks -= 1;
        if (cur.slice_ticks == 0) {
            // Time slice expired — re-enqueue and schedule next
            cur.state = .runnable;
            cur.slice_ticks = sliceMs(cur.latency_class);
            global_rq.?.enqueue(cur) catch {};
            schedule();
        }
    }
}

// ----------------------------------------------------------------
// schedule(): pick next runnable task and switch to it
// ----------------------------------------------------------------

pub fn schedule() void {
    const rq = &(global_rq orelse return);
    const next_id = rq.pickNext() orelse {
        // Nothing runnable — stay on idle
        return;
    };
    const next = &(task_table[next_id] orelse return);
    const prev = current_task;

    // Update vruntime of outgoing task
    if (prev) |p| {
        p.vruntime += TICK_MS * 1_000_000; // convert ms to ns
        p.state = .runnable;
    }

    next.state = .running;
    current_task = next;

    // Update UART / console with new PID for debugging
    console.print("[sched] switch → pid={} task={}\n", .{ next.pid, next.id });

    // Update TSS.RSP0 to top of next task's kernel stack
    ctx.setRsp0(next.kstack_top);

    // Perform the register-level context switch
    const prev_rsp_ptr: *u64 = if (prev) |p| &p.saved_rsp else &idle_saved_rsp;
    ctx.switchTo(prev_rsp_ptr, next.saved_rsp, next.kstack_top);
    // Returns here in `next`'s context
}

// ----------------------------------------------------------------
// start(): enter the scheduler loop, enable interrupts
// ----------------------------------------------------------------

/// Called from kmain after all subsystems are ready.
/// Enables interrupts and drops into the idle loop.
/// The APIC tick will preempt this and run the first enqueued task.
pub fn start() noreturn {
    // Capture idle RSP so switchTo can save into it
    idle_task.saved_rsp = 0; // will be filled by first switchTo
    current_task = &idle_task;

    console.print("[sched] starting, enabling interrupts\n", .{});
    asm volatile ("sti");

    // Idle loop: HLT until next interrupt
    while (true) {
        asm volatile ("hlt");
    }
}

// ----------------------------------------------------------------
// Tests
// ----------------------------------------------------------------

test "Task basePriority" {
    const rt  = Task.new(1, .realtime);
    const inf = Task.new(2, .inference);
    const bt  = Task.new(3, .batch);
    try std.testing.expectEqual(rt.basePriority(), 0);
    try std.testing.expectEqual(inf.basePriority(), 24);
    try std.testing.expectEqual(bt.basePriority(), 48);
}

test "Task slice_ticks" {
    const interactive = Task.new(1, .interactive);
    try std.testing.expectEqual(interactive.slice_ticks, SLICE_MS.interactive);
    const inf = Task.new(2, .inference);
    try std.testing.expectEqual(inf.slice_ticks, SLICE_MS.inference);
}

test "RunQueue O(1) pickNext priority order" {
    var rq = RunQueue.init(std.testing.allocator);
    defer rq.deinit();
    const bt  = Task.new(30, .batch);
    const rt  = Task.new(10, .realtime);
    const inf = Task.new(20, .inference);
    try rq.enqueue(&bt);
    try rq.enqueue(&rt);
    try rq.enqueue(&inf);
    // realtime first, then inference, then batch
    try std.testing.expectEqual(rq.pickNext(), 10);
    try std.testing.expectEqual(rq.pickNext(), 20);
    try std.testing.expectEqual(rq.pickNext(), 30);
    try std.testing.expectEqual(rq.pickNext(), null);
}

test "sliceMs values" {
    try std.testing.expectEqual(sliceMs(.realtime),    1);
    try std.testing.expectEqual(sliceMs(.interactive), 5);
    try std.testing.expectEqual(sliceMs(.inference),  50);
    try std.testing.expectEqual(sliceMs(.batch),      20);
}
