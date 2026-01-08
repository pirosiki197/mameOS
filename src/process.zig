const std = @import("std");
const log = std.log.scoped(.process);
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub var global_manager: ProcessManager = undefined;

pub const ProcessManager = struct {
    allocator: Allocator,
    run_queue: Queue(*Process),
    current: *Process,

    const Self = @This();

    pub fn init(allocator: Allocator) !ProcessManager {
        const boot_proc = try allocator.create(Process);
        boot_proc.* = .{
            .pid = 0,
            .state = .runnable,
            .sp = 0,
            .stack = &[_]u8{},
        };
        return .{
            .allocator = allocator,
            .run_queue = try Queue(*Process).init(allocator),
            .current = boot_proc,
        };
    }

    pub fn spawn(self: *Self, pc: usize) !void {
        const pid = 1;
        const proc = try Process.new(self.allocator, pid, pc);
        try self.run_queue.push(proc);
    }

    pub fn yield(self: *Self) void {
        const next = self.run_queue.pop() orelse return;

        const prev = self.current;
        self.current = next;

        if (prev.state == .runnable) {
            self.run_queue.push(prev) catch unreachable;
        }

        asm volatile ("call switchContext"
            :
            : [a0] "{a0}" (&prev.sp),
              [a1] "{a1}" (&next.sp),
        );
    }
};

pub const Process = struct {
    pid: u32,
    state: State,
    sp: usize,
    stack: []u8,

    const Self = @This();
    const State = enum {
        unused,
        runnable,
    };

    fn new(allocator: Allocator, pid: u32, pc: usize) !*Self {
        const proc = try allocator.create(Self);
        const stack = try allocator.alignedAlloc(u8, Alignment.fromByteUnits(4096), 8192);

        var sp_addr = @intFromPtr(stack.ptr) + stack.len;
        sp_addr &= ~@as(usize, 15); // 16 byte alignment
        sp_addr -= 8 * 13;
        const sp: [*]usize = @ptrFromInt(sp_addr);

        sp[0] = @intFromPtr(&processEntry); // ra
        sp[1] = pc; // s0
        for (2..13) |i| {
            sp[i] = 0; // s1 - s11
        }

        proc.* = .{
            .pid = pid,
            .state = .runnable,
            .sp = sp_addr,
            .stack = stack,
        };
        return proc;
    }
};

fn processEntry() callconv(.naked) noreturn {
    asm volatile (
        \\jalr (s0)
        \\
        \\call processExit
    );
}

export fn processExit() void {
    log.info("process exiting...", .{});
    const proc = global_manager.current;
    proc.state = .unused;
    global_manager.yield();
}

export fn switchContext(prev_sp: *usize, next_sp: *usize) callconv(.naked) void {
    _ = prev_sp;
    _ = next_sp;
    asm volatile (
        \\addi sp, sp, -13 * 8
        \\sd ra,  0 * 8(sp)
        \\sd s0,  1 * 8(sp)
        \\sd s1,  2 * 8(sp)
        \\sd s2,  3 * 8(sp)
        \\sd s3,  4 * 8(sp)
        \\sd s4,  5 * 8(sp)
        \\sd s5,  6 * 8(sp)
        \\sd s6,  7 * 8(sp)
        \\sd s7,  8 * 8(sp)
        \\sd s8,  9 * 8(sp)
        \\sd s9,  10 * 8(sp)
        \\sd s10, 11 * 8(sp)
        \\sd s11, 12 * 8(sp)
        \\
        \\sd sp, (a0)
        \\ld sp, (a1)
        \\
        \\ld ra,  0 * 8(sp)
        \\ld s0,  1 * 8(sp)
        \\ld s1,  2 * 8(sp)
        \\ld s2,  3 * 8(sp)
        \\ld s3,  4 * 8(sp)
        \\ld s4,  5 * 8(sp)
        \\ld s5,  6 * 8(sp)
        \\ld s6,  7 * 8(sp)
        \\ld s7,  8 * 8(sp)
        \\ld s8,  9 * 8(sp)
        \\ld s9,  10 * 8(sp)
        \\ld s10, 11 * 8(sp)
        \\ld s11, 12 * 8(sp)
        \\
        \\addi sp, sp, 13 * 8
        \\ret
    );
}

fn Queue(T: type) type {
    return struct {
        allocator: Allocator,
        data: []T,
        _head: usize,
        _tail: usize,
        size: usize,

        const Self = @This();

        fn init(allocator: Allocator) !Self {
            return .{
                .allocator = allocator,
                .data = try allocator.alloc(T, 4),
                ._head = 0,
                ._tail = 0,
                .size = 0,
            };
        }

        fn deinit(self: *Self) void {
            self.allocator.free(self.data);
        }

        fn push(self: *Self, v: T) !void {
            if (self.size == self.data.len) {
                const new_data = try self.allocator.alloc(T, 2 * self.data.len);
                const first_len = self.data.len - self._head;
                @memcpy(new_data[0..first_len], self.data[self._head..self.data.len]);
                const second_len = self._head;
                @memcpy(new_data[first_len .. first_len + second_len], self.data[0..second_len]);

                self._head = 0;
                self._tail = self.data.len;
                self.allocator.free(self.data);
                self.data = new_data;
            }
            self.size += 1;
            self.data[self._tail] = v;
            self._tail = (self._tail + 1) % self.data.len;
        }

        fn pop(self: *Self) ?T {
            if (self.size == 0) return null;
            const res = self.data[self._head];
            self._head = (self._head + 1) % self.data.len;
            self.size -= 1;
            return res;
        }

        fn peek(self: *Self) ?T {
            if (self.size == 0) return null;
            return self.data[self._head];
        }
    };
}
