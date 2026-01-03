const std = @import("std");
const log = std.log.scoped(.boot);

const mame = @import("mame");
const klog = mame.klog;
const sbi = mame.sbi;

extern const __stack_top: anyopaque;
extern var __bss: [*]u8;
extern const __bss_end: anyopaque;

pub const std_options = klog.default_log_options;

fn kernelMain() !void {
    const bss_len = @intFromPtr(&__bss_end) - @intFromPtr(&__bss);
    @memset(__bss[0..bss_len], 0);

    log.info("hello, world!", .{});

    while (true) {}
}

export fn trampoline() void {
    kernelMain() catch {
        while (true) {}
    };
}

export fn boot() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\mv sp, %[stack_top]
        \\j trampoline
        :
        : [stack_top] "r" (@intFromPtr(&__stack_top)),
    );
}
