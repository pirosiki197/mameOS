const std = @import("std");
const log = std.log.scoped(.syscall);

const mame = @import("mame");
const sbi = mame.sbi;

const process_manager = &mame.process.global_manager;
const scheduler = &mame.process.global_scheduler;
const page_allocator = &mame.mem.page_allocator;

pub const SyscallArgs = struct {
    arg0: usize,
    arg1: usize,
    arg2: usize,
    arg3: usize,
};

pub fn handle(id: usize, args: SyscallArgs) usize {
    switch (id) {
        1 => return sys_putchar(@truncate(args.arg0)),
        2 => sys_exit(args.arg0),
        12 => return sys_sbrk(args.arg0),
        else => {
            log.err("Unknown syscall ID: {} (arg0: {x})", .{ id, args.arg0 });
            sys_exit(1);
        },
    }
}

fn sys_putchar(c: u8) usize {
    _ = sbi.console.write(&.{c}) catch {};
    return 0;
}

fn sys_exit(code: usize) noreturn {
    const current_thread = scheduler.current;
    log.info("Process {} (TID {}) exited with code {}", .{
        current_thread.proc.pid,
        current_thread.tid,
        code,
    });

    process_manager.markAsZombie(current_thread);
    scheduler.yield();

    unreachable;
}

fn sys_sbrk(size: usize) usize {
    const err_code: usize = @bitCast(@as(isize, -1));

    const process = scheduler.current.proc;
    const old_brk = process.heap_brk;
    const page_align = std.mem.Alignment.fromByteUnits(4096);

    const current_page_end = page_align.forward(process.heap_brk);

    if (process.heap_brk + size <= current_page_end) {
        process.heap_brk += size;
        return old_brk;
    }

    const increase = process.heap_brk + size - current_page_end;
    const memory = page_allocator.alloc(increase) catch return err_code;
    process.page_table.mapMemory(
        current_page_end,
        memory,
        .read_write,
        true,
    ) catch return err_code;
    process.heap_brk += size;

    return old_brk;
}
