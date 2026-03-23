const std = @import("std");
const log = std.log.scoped(.process);
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const mame = @import("mame");
const am = mame.am;
const timer = mame.timer;
const PageAllocator = mame.mem.PageAllocator;
const PageTable = mame.page.PageTable;
const TrapFrame = mame.trap.TrapFrame;
const Phys = mame.mem.Phys;
const Virt = mame.mem.Virt;
const va2pa = mame.page.va2pa;

pub var global_manager: ProcessManager = undefined;
pub var global_scheduler: Scheduler = undefined;

const user_load_addr = 0x1000;
const user_stack_addr = 0x1000_0000;

pub fn init(page_allocator: *PageAllocator, allocator: Allocator) !void {
    const boot_proc = try allocator.create(Process);
    boot_proc.* = .{
        .pid = 0,
        .page_table = .fromActualSatp(),
        .user = false,
    };
    const thread = try allocator.create(Thread);
    thread.* = .{
        .tid = 0,
        .proc = boot_proc,
        .state = .runnable,
        .kernel_sp = 0,
        .user_stack = &.{},
        .kernel_stack = &[_]u8{},
    };

    global_manager = .init(page_allocator, allocator);
    global_scheduler = .init(thread);
}

pub const ProcessManager = struct {
    page_allocator: *PageAllocator,
    allocator: Allocator,
    processes: std.DoublyLinkedList = .{},
    zombie_threads: std.DoublyLinkedList = .{},
    next_pid: u32 = 0,
    next_tid: u32 = 0,

    const Self = @This();

    pub fn init(page_allocator: *PageAllocator, allocator: Allocator) Self {
        return .{
            .page_allocator = page_allocator,
            .allocator = allocator,
        };
    }

    pub fn spawnKernel(self: *Self, pc: usize) !void {
        const proc = try self.createKernelProcess();
        const thread = try self.createKernelThread(proc, pc);
        global_scheduler.push(thread);
    }

    pub fn spawnUser(self: *Self, bin: []const u8) !void {
        const proc = try self.createUserProcess(bin);
        const thread = try self.createUserThread(proc);
        global_scheduler.push(thread);
    }

    fn createKernelProcess(self: *Self) !*Process {
        return self.createProcess(.fromActualSatp(), false);
    }

    fn createUserProcess(self: *Self, bin: []const u8) !*Process {
        const page_table = try PageTable.newProcessTable(self.page_allocator);

        const user_bin = try self.page_allocator.allocPages(PageAllocator.numPages(bin.len));
        @memcpy(user_bin[0..bin.len], bin);
        try page_table.mapRange(
            self.page_allocator,
            user_load_addr,
            va2pa(@intFromPtr(user_bin.ptr)),
            user_bin.len,
            .read_execute,
            true,
        );

        return self.createProcess(page_table, true);
    }

    fn createProcess(self: *Self, page_table: PageTable, user: bool) !*Process {
        const proc = try self.allocator.create(Process);
        proc.* = Process.init(self.allocPid(), page_table, user);

        self.processes.append(&proc.node);
        return proc;
    }

    fn createKernelThread(self: *Self, proc: *Process, pc: usize) !*Thread {
        const stack = try self.page_allocator.allocPages(2); // 8KiB
        const thread = try self.allocator.create(Thread);
        thread.* = try .initKernel(self.allocTid(), proc, pc, stack);
        proc.threads.append(&thread.proc_node);
        return thread;
    }

    fn createUserThread(self: *Self, proc: *Process) !*Thread {
        const user_stack = try self.page_allocator.allocPages(2);
        try proc.page_table.mapRange(
            self.page_allocator,
            user_stack_addr,
            va2pa(@intFromPtr(user_stack.ptr)),
            user_stack.len,
            .read_write,
            true,
        );
        const kernel_stack = try self.page_allocator.allocPages(1);
        const thread = try self.allocator.create(Thread);
        thread.* = .initUser(self.allocTid(), proc, user_load_addr, user_stack, kernel_stack);
        return thread;
    }

    pub fn markAsZombie(self: *Self, thread: *Thread) void {
        thread.state = .zombie;
        self.zombie_threads.append(&thread.queue_node);
    }

    pub fn cleanupZombies(self: *Self) void {
        while (self.zombie_threads.pop()) |node| {
            log.info("cleaning up process...", .{});
            const thread: *Thread = @fieldParentPtr("queue_node", node);
            const proc = thread.proc;

            proc.threads.remove(&thread.proc_node);
            thread.deinit(self.allocator);
            self.allocator.destroy(thread);

            if (proc.threads.first == null) {
                proc.state = .zombie;
                proc.page_table.deinit(self.page_allocator);
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

        if (next.proc != prev.proc) {
            mame.page.enablePaging(next.proc.page_table.root_paddr);
        }

        if (next.proc.user) {
            asm volatile ("csrw sscratch, %[stack]"
                :
                : [stack] "r" (@intFromPtr(next.kernel_stack.ptr) + next.kernel_stack.len),
            );
        } else {
            asm volatile ("csrw sscratch, x0");
        }

        asm volatile ("call switchContext"
            :
            : [a0] "{a0}" (&prev.kernel_sp),
              [a1] "{a1}" (&next.kernel_sp),
        );
    }
};

pub const Process = struct {
    pid: u32,
    threads: std.DoublyLinkedList = .{},
    state: State = .live,
    page_table: PageTable,
    user: bool,
    node: std.DoublyLinkedList.Node = .{},

    const Self = @This();
    const State = enum {
        zombie,
        live,
    };

    fn init(pid: u32, page_table: PageTable, user: bool) Self {
        return .{
            .pid = pid,
            .page_table = page_table,
            .user = user,
        };
    }
};

pub const Thread = struct {
    tid: usize,
    proc: *Process,
    state: State,
    kernel_sp: Virt,
    user_stack: []u8 = &.{},
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

    fn initKernel(tid: usize, proc: *Process, pc: usize, stack: []u8) !Self {
        var sp_addr = @intFromPtr(stack.ptr) + stack.len;

        sp_addr -= @sizeOf(TrapFrame);
        var frame: *TrapFrame = @ptrFromInt(sp_addr);
        frame.ra = @intFromPtr(&processExit);
        frame.sp = @intFromPtr(stack.ptr) + stack.len;
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
            .kernel_sp = sp_addr,
            .kernel_stack = stack,
        };
    }

    fn initUser(tid: usize, proc: *Process, pc: usize, user_stack: []u8, kernel_stack: []u8) Thread {
        var kernel_sp = @intFromPtr(kernel_stack.ptr) + kernel_stack.len;

        kernel_sp -= @sizeOf(TrapFrame);
        var frame: *TrapFrame = @ptrFromInt(kernel_sp);
        frame.ra = @intFromPtr(&processExit);
        frame.sp = user_stack_addr + user_stack.len;
        frame.sstatus = @bitCast(am.Sstatus{
            .spie = true,
            .spp = 0,
        });
        frame.sepc = pc;

        kernel_sp -= 8 * 13;
        const sp: [*]usize = @ptrFromInt(kernel_sp);
        sp[0] = @intFromPtr(&forkret);
        for (1..13) |i| {
            sp[i] = 0; // s0 - s11
        }

        return .{
            .tid = tid,
            .proc = proc,
            .state = .runnable,
            .kernel_sp = kernel_sp,
            .user_stack = user_stack,
            .kernel_stack = kernel_stack,
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
        ::: .{ .memory = true });
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
