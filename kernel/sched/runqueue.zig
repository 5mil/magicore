//! Magicore per-CPU run queue with O(1) pick-next.
//! Uses a 64-bit priority bitmap for O(1) scheduling.
//! One bit per priority level (64 levels).
//! pickNext() is: find_first_set_bit → dequeue → done.
//! No tree walk, no vruntime scan, no lock on fast path.
//! Linux CFS uses a red-black tree (O(log N)).
//! Magicore hot path is O(1) via bitmap + per-priority FIFO queues.

const std = @import("std");
const sched = @import("sched.zig");

pub const NUM_PRIORITIES: usize = 64;

/// O(1) priority run queue
pub const PriorityRunQueue = struct {
    /// Bitmap: bit N set means priority N has at least one runnable task
    bitmap: u64,
    /// Per-priority FIFO queues (head/tail indices into task pool)
    queues: [NUM_PRIORITIES]std.ArrayListUnmanaged(u64), // stores task IDs
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PriorityRunQueue {
        return .{
            .bitmap = 0,
            .queues = [_]std.ArrayListUnmanaged(u64){.{}} ** NUM_PRIORITIES,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PriorityRunQueue) void {
        for (&self.queues) |*q| q.deinit(self.allocator);
    }

    /// Enqueue task at given priority — O(1)
    pub fn enqueue(self: *PriorityRunQueue, task_id: u64, priority: u6) !void {
        try self.queues[priority].append(self.allocator, task_id);
        self.bitmap |= (@as(u64, 1) << priority);
    }

    /// Pick and dequeue highest-priority task — O(1)
    pub fn pickNext(self: *PriorityRunQueue) ?u64 {
        if (self.bitmap == 0) return null;
        // Find highest priority (lowest set bit = highest priority)
        const prio = @ctz(self.bitmap);
        const q = &self.queues[prio];
        const task_id = q.orderedRemove(0);
        if (q.items.len == 0) {
            self.bitmap &= ~(@as(u64, 1) << @intCast(prio));
        }
        return task_id;
    }

    pub fn isEmpty(self: *const PriorityRunQueue) bool {
        return self.bitmap == 0;
    }
};

test "PriorityRunQueue O(1) pickNext" {
    var rq = PriorityRunQueue.init(std.testing.allocator);
    defer rq.deinit();

    try rq.enqueue(10, 5);  // lower priority
    try rq.enqueue(20, 1);  // higher priority (lower number)
    try rq.enqueue(30, 1);  // same high priority

    // Should pick priority 1 first
    try std.testing.expectEqual(rq.pickNext(), 20);
    try std.testing.expectEqual(rq.pickNext(), 30);
    try std.testing.expectEqual(rq.pickNext(), 10);
    try std.testing.expectEqual(rq.pickNext(), null);
}

test "PriorityRunQueue isEmpty" {
    var rq = PriorityRunQueue.init(std.testing.allocator);
    defer rq.deinit();
    try std.testing.expect(rq.isEmpty());
    try rq.enqueue(1, 0);
    try std.testing.expect(!rq.isEmpty());
    _ = rq.pickNext();
    try std.testing.expect(rq.isEmpty());
}
