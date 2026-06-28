//! Magicore scheduler.
//! CFS-inspired but designed for AI/inference workloads:
//! - Latency classes (interactive, batch, realtime, inference)
//! - No big kernel lock
//! - Per-CPU run queues with work stealing
//! - Explicit priority inheritance for IPC-heavy workloads

const std = @import("std");

/// Latency class for a task
pub const LatencyClass = enum {
    /// Low-latency interactive (UI, input handling)
    interactive,
    /// Background batch (compilation, indexing)
    batch,
    /// Hard realtime (audio, sensors)
    realtime,
    /// AI/inference (model forward pass, token generation)
    inference,
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
    id: u64,
    state: TaskState,
    latency_class: LatencyClass,
    vruntime: u64,   // virtual runtime (ns)
    priority: i8,    // -20..19, lower = higher priority
    cpu: u32,        // assigned CPU
    stack_ptr: u64,
    page_table: u64,

    pub fn new(id: u64, class: LatencyClass) Task {
        return .{
            .id = id,
            .state = .runnable,
            .latency_class = class,
            .vruntime = 0,
            .priority = 0,
            .cpu = 0,
            .stack_ptr = 0,
            .page_table = 0,
        };
    }
};

/// Per-CPU run queue
pub const RunQueue = struct {
    tasks: std.ArrayList(Task),
    current: ?*Task,

    pub fn init(allocator: std.mem.Allocator) RunQueue {
        return .{
            .tasks = std.ArrayList(Task).init(allocator),
            .current = null,
        };
    }

    /// Pick next task using vruntime (CFS-style)
    pub fn pickNext(self: *RunQueue) ?*Task {
        var best: ?*Task = null;
        for (self.tasks.items) |*task| {
            if (task.state != .runnable) continue;
            if (best == null or task.vruntime < best.?.vruntime) {
                best = task;
            }
        }
        return best;
    }
};

pub fn init() error{OutOfMemory}!void {
    // TODO: allocate per-CPU run queues
    // TODO: create idle task for each CPU
    // TODO: wire timer interrupt -> tick()
}

/// Called from timer interrupt — advance vruntime, maybe preempt
pub fn tick(elapsed_ns: u64) void {
    _ = elapsed_ns;
    // TODO: update current task vruntime
    // TODO: check if preemption needed
}

/// Transfer control to scheduler — does not return
pub fn start() noreturn {
    // TODO: enable interrupts, drop to idle loop
    while (true) {
        asm volatile ("hlt");
    }
}

test "Task creation" {
    const t = Task.new(1, .inference);
    try std.testing.expectEqual(t.id, 1);
    try std.testing.expectEqual(t.latency_class, .inference);
    try std.testing.expectEqual(t.state, .runnable);
}

test "RunQueue pickNext empty" {
    var rq = RunQueue.init(std.testing.allocator);
    try std.testing.expect(rq.pickNext() == null);
}
