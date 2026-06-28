//! Magicore scheduler.
//! CFS-inspired with first-class AI/inference latency class.
//! Per-CPU run queues with O(1) pick-next via priority bitmap.
//! Four latency classes: realtime, interactive, inference, batch.

const std = @import("std");
const mm  = @import("../mm/mm.zig");

/// Latency class — determines scheduling policy
pub const LatencyClass = enum {
    /// Hard realtime (audio, sensors) — fixed priority, preempt immediately
    realtime,
    /// Low-latency interactive (UI, shell) — fast wakeup
    interactive,
    /// AI model forward pass — large time slice, NUMA-pinned, never preempted by batch
    inference,
    /// Background (compilation, indexing) — lowest priority
    batch,
};

/// Task state
pub const TaskState = enum {
    runnable,
    running,
    blocked,
    zombie,
};

/// Task control block
pub const Task = struct {
    id:            u64,
    state:         TaskState,
    latency_class: LatencyClass,
    vruntime:      u64,  // virtual runtime (ns)
    priority:      i8,   // -20..19
    cpu:           u32,
    stack_ptr:     u64,
    page_table:    u64,

    pub fn new(id: u64, class: LatencyClass) Task {
        return .{
            .id            = id,
            .state         = .runnable,
            .latency_class = class,
            .vruntime      = 0,
            .priority      = 0,
            .cpu           = 0,
            .stack_ptr     = 0,
            .page_table    = 0,
        };
    }

    /// Map latency class to a base priority bucket (0 = highest)
    pub fn basePriority(self: *const Task) u6 {
        return switch (self.latency_class) {
            .realtime    => 0,
            .interactive => 16,
            .inference   => 24,
            .batch       => 48,
        };
    }
};

/// Per-CPU run queue (O(1) bitmap scheduler)
pub const RunQueue = struct {
    /// 64-bit bitmap: bit N set → priority N has at least one runnable task
    bitmap: u64,
    /// Per-priority FIFO task ID queues
    queues: [64]std.ArrayListUnmanaged(u64),
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
        self.bitmap |= (@as(u64, 1) << prio);
    }

    /// O(1) pick-next: find first set bit, dequeue head of that priority
    pub fn pickNext(self: *RunQueue) ?u64 {
        if (self.bitmap == 0) return null;
        const prio: u6 = @intCast(@ctz(self.bitmap));
        const q = &self.queues[prio];
        const id = q.orderedRemove(0);
        if (q.items.len == 0) self.bitmap &= ~(@as(u64, 1) << prio);
        return id;
    }
};

/// Global run queue — single CPU for now, SMP later
var global_rq: ?RunQueue = null;

pub fn init() error{OutOfMemory}!void {
    global_rq = RunQueue.init(mm.kernel_allocator);
    // Idle task (id=0, batch class — runs when nothing else is runnable)
    const idle = Task.new(0, .batch);
    try global_rq.?.enqueue(&idle);
}

/// Advance scheduler by elapsed_ns — called from timer interrupt
pub fn tick(elapsed_ns: u64) void {
    _ = elapsed_ns;
    // TODO: update vruntime of current task, check preemption
}

/// Begin scheduling — does not return
pub fn start() noreturn {
    // Enable interrupts and drop into idle loop
    // Real scheduler will preempt this via timer IRQ
    asm volatile ("sti");
    while (true) {
        asm volatile ("hlt");
    }
}

test "Task basePriority" {
    const rt = Task.new(1, .realtime);
    const inf = Task.new(2, .inference);
    const bt  = Task.new(3, .batch);
    try std.testing.expectEqual(rt.basePriority(), 0);
    try std.testing.expectEqual(inf.basePriority(), 24);
    try std.testing.expectEqual(bt.basePriority(), 48);
}

test "RunQueue O(1) pickNext" {
    var rq = RunQueue.init(std.testing.allocator);
    defer rq.deinit();
    const rt  = Task.new(10, .realtime);
    const inf = Task.new(20, .inference);
    try rq.enqueue(&rt);
    try rq.enqueue(&inf);
    // realtime has lower priority index → picked first
    try std.testing.expectEqual(rq.pickNext(), 10);
    try std.testing.expectEqual(rq.pickNext(), 20);
    try std.testing.expectEqual(rq.pickNext(), null);
}
