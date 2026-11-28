//! Shared allocation-backed event queue with O(1) amortized push/pop.
//! Borrowed event payloads are stored by value; this queue never copies them.

const std = @import("std");
const Event = @import("Event.zig");

pub const Queue = struct {
    alloc: std.mem.Allocator,
    items: []Event.Core = &.{},
    capacity: usize = 0,
    head: usize = 0,
    len: usize = 0,

    pub fn init(alloc: std.mem.Allocator) Queue {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Queue) void {
        if (self.capacity > 0) self.alloc.free(self.items);
        self.items = &.{};
        self.capacity = 0;
        self.head = 0;
        self.len = 0;
    }

    pub fn count(self: *const Queue) usize {
        return self.len;
    }

    /// Appends one event. Returns false only when the growth allocation fails.
    pub fn push(self: *Queue, ev: Event.Core) bool {
        if (self.len == self.capacity) {
            const new_capacity: usize = if (self.capacity == 0) 8 else self.capacity * 2;
            const buf = self.alloc.alloc(Event.Core, new_capacity) catch return false;
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                buf[i] = self.items[(self.head + i) % self.capacity];
            }
            if (self.capacity > 0) self.alloc.free(self.items);
            self.items = buf;
            self.capacity = new_capacity;
            self.head = 0;
        }
        self.items[(self.head + self.len) % self.capacity] = ev;
        self.len += 1;
        return true;
    }

    pub fn pop(self: *Queue) ?Event.Core {
        if (self.len == 0) return null;
        const ev = self.items[self.head];
        self.head = (self.head + 1) % self.capacity;
        self.len -= 1;
        return ev;
    }
};

test "queue FIFO order and wraparound" {
    const alloc = std.testing.allocator;
    var q = Queue.init(alloc);
    defer q.deinit();

    try std.testing.expect(q.pop() == null);
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        try std.testing.expect(q.push(.{ .custom = .{
            .window_id = @intCast(i),
            .ev_type = @intCast(i),
            .act = .{ .uint = @intCast(i) },
            .act_2 = .{ .uint = 0 },
        } }));
    }
    // Force wraparound after growth.
    _ = q.pop();
    _ = q.pop();
    try std.testing.expect(q.push(Event.Core.unknown));
    try std.testing.expect(q.push(Event.Core.unknown));

    i = 2;
    while (i < 32) : (i += 1) {
        const ev = q.pop().?;
        try std.testing.expectEqual(@as(u32, @intCast(i)), ev.custom.window_id);
    }
    try std.testing.expectEqual(std.meta.activeTag(q.pop().?), .unknown);
    try std.testing.expectEqual(std.meta.activeTag(q.pop().?), .unknown);
    try std.testing.expect(q.pop() == null);
}

test "queue deinit is repeatable" {
    const alloc = std.testing.allocator;
    var q = Queue.init(alloc);
    try std.testing.expect(q.push(Event.Core.none));
    q.deinit();
    q.deinit();
}
