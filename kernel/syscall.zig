const std = @import("std");
const log = std.log.scoped(.syscall);

const mame = @import("mame");
const sbi = mame.sbi;

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
        else => return 1,
    }
}

fn sys_putchar(c: u8) usize {
    _ = sbi.console.write(&.{c}) catch {};
    return 0;
}

fn sys_exit(code: usize) noreturn {
    const current_thread = mame.process.global_scheduler.current;
    log.info("Process {} (TID {}) exited with code {}", .{
        current_thread.proc.pid,
        current_thread.tid,
        code,
    });

    mame.process.global_manager.markAsZombie(current_thread);
    mame.process.global_scheduler.yield();

    unreachable;
}
