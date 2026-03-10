const std = @import("std");
const log = std.log.scoped(.process);
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const mame = @import("mame");
const am = mame.am;
const timer = mame.timer;
const TrapFrame = mame.trap.TrapFrame;

pub var global_manager: ProcessManager = undefined;
pub var global_scheduler: Scheduler = undefined;

pub fn init(allocator: Allocator) !void {
    const boot_proc = try allocator.create(Process);
    boot_proc.* = .{
        .pid = 0,
    };
    const thread = try allocator.create(Thread);
    thread.* = .{
        .tid = 0,
        .proc = boot_proc,
        .state = .runnable,
        .sp = 0,
        .kernel_stack = &[_]u8{},
    };

    global_manager = .init(allocator);
    global_scheduler = .init(thread);
}

pub const ProcessManager = struct {
    allocator: Allocator,
    processes: std.DoublyLinkedList = .{},
    zombie_threads: std.DoublyLinkedList = .{},
    next_pid: u32 = 0,
    next_tid: u32 = 0,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn spawn(self: *Self, pc: usize) !void {
        const proc = try self.createProcess();

        const thread = try self.createThread(proc, pc);

        global_scheduler.push(thread);
    }

    fn createProcess(self: *Self) !*Process {
        const proc = try self.allocator.create(Process);
        proc.pid = self.allocPid();
        self.processes.append(&proc.node);
        return proc;
    }

    fn createThread(self: *Self, proc: *Process, pc: usize) !*Thread {
        const thread = try self.allocator.create(Thread);
        thread.* = try Thread.init(self.allocator, self.allocTid(), proc, pc);
        proc.threads.append(&thread.proc_node);
        return thread;
    }

    fn markAsZombie(self: *Self, thread: *Thread) void {
        thread.state = .zombie;
        self.zombie_threads.append(&thread.queue_node);
    }

    pub fn cleanupZombies(self: *Self) void {
        while (self.zombie_threads.pop()) |node| {
            const thread: *Thread = @fieldParentPtr("queue_node", node);
            const proc = thread.proc;

            proc.threads.remove(&thread.proc_node);
            thread.deinit(self.allocator);
            self.allocator.destroy(thread);

            if (proc.threads.first == null) {
                proc.state = .zombie;
                // TODO: cleanup process memory map
            }
        }
    }

    fn allocPid(self: *Self) u32 {
        const pid = self.next_pid;
        self.next_pid += 1;
        return pid;
    }
    fn allocTid(self: *Self) u32 {
        const tid = self.next_tid;
        self.next_tid += 1;
        return tid;
    }
};

pub const Scheduler = struct {
    run_queue: std.DoublyLinkedList,
    current: *Thread,

    const Self = @This();

    fn init(initial_thread: *Thread) Scheduler {
        return .{
            .run_queue = .{},
            .current = initial_thread,
        };
    }

    pub fn push(self: *Self, thread: *Thread) void {
        self.run_queue.append(&thread.queue_node);
    }

    pub fn yield(self: *Self) void {
        const next_node = self.run_queue.popFirst() orelse return;
        const next: *Thread = @fieldParentPtr("queue_node", next_node);

        const prev = self.current;
        self.current = next;

        if (prev.state == .runnable) {
            self.run_queue.append(&prev.queue_node);
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
    threads: std.DoublyLinkedList = .{},
    state: State = .live,
    node: std.DoublyLinkedList.Node = .{},

    const Self = @This();
    const State = enum {
        zombie,
        live,
    };

    fn init(pid: u32) !Self {
        return .{ .pid = pid };
    }
};

pub const Thread = struct {
    tid: usize,
    proc: *Process,
    state: State,
    sp: usize,
    kernel_stack: []u8,
    queue_node: std.DoublyLinkedList.Node = .{},
    proc_node: std.DoublyLinkedList.Node = .{},

    const Self = @This();
    const State = enum {
        unused,
        runnable,
        sleeping,
        zombie,
    };

    fn init(allocator: Allocator, tid: usize, proc: *Process, pc: usize) !Self {
        const stack = try allocator.alignedAlloc(u8, Alignment.fromByteUnits(4096), 8192);
        var sp_addr = @intFromPtr(stack.ptr) + stack.len;

        sp_addr -= @sizeOf(TrapFrame);
        var frame: *TrapFrame = @ptrFromInt(sp_addr);
        frame.ra = @intFromPtr(&processExit);
        frame.sstatus = @bitCast(am.Sstatus{
            .spie = true,
            .spp = 1,
        });
        frame.sepc = pc;

        sp_addr -= 8 * 13;
        const sp: [*]usize = @ptrFromInt(sp_addr);
        sp[0] = @intFromPtr(&forkret);
        for (1..13) |i| {
            sp[i] = 0; // s0 - s11
        }

        return .{
            .tid = tid,
            .proc = proc,
            .state = .runnable,
            .sp = sp_addr,
            .kernel_stack = stack,
        };
    }

    fn deinit(self: Self, allocator: Allocator) void {
        allocator.free(self.kernel_stack);
    }
};

fn forkret() callconv(.naked) void {
    asm volatile (
        \\j kernel_target
    );
}

fn processEntry() callconv(.naked) noreturn {
    asm volatile (
        \\jalr (s0)
        \\
        \\call processExit
    );
}

fn processExit() void {
    const thread = global_scheduler.current;
    global_manager.markAsZombie(thread);
    global_scheduler.yield();
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

pub fn sleep(ticks: u64) void {
    const thread = global_scheduler.current;
    const now = am.getTime();

    timer.global_manager.addTimer(now + ticks, thread) catch |err| {
        log.err("failed to add timer: {}", .{err});
        return;
    };
    thread.state = .sleeping;
    global_scheduler.yield();
}
