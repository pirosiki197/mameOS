const std = @import("std");
const log = std.log.scoped(.timer);
const Allocator = std.mem.Allocator;

const mame = @import("mame");
const process = mame.process;
const Process = process.Process;
const Thread = process.Thread;

pub var global_manager: TimerManager = undefined;

pub fn init(allocator: Allocator) void {
    global_manager = .init(allocator);
}

pub const TimerEvent = struct {
    expires: u64,
    thread: ?*Thread,
    callback: ?*const fn () void = null,

    const Self = @This();

    fn compare(_: void, a: Self, b: Self) std.math.Order {
        return std.math.order(a.expires, b.expires);
    }
};

pub const TimerManager = struct {
    events: EventQueue,

    const Self = @This();
    const EventQueue = std.PriorityQueue(TimerEvent, void, TimerEvent.compare);

    fn init(allocator: Allocator) Self {
        return .{
            .events = EventQueue.init(allocator, {}),
        };
    }

    pub fn addTimer(self: *Self, expires: u64, thread: *Thread) !void {
        try self.events.add(.{
            .expires = expires,
            .thread = thread,
        });
    }

    pub fn tick(self: *Self, current_time: u64) void {
        while (self.events.peek()) |event| {
            if (event.expires > current_time) break;
            const expired = self.events.remove();

            if (expired.thread) |proc| {
                proc.state = .runnable;
                process.global_scheduler.run_queue.push(proc) catch unreachable;
            }

            if (expired.callback) |callback| {
                callback();
            }
        }
    }
};
