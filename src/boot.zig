extern const __stack_top: anyopaque;
extern var __bss: [*]u8;
extern const __bss_end: anyopaque;

export fn kernelMain() void {
    const bss_len = @intFromPtr(&__bss_end) - @intFromPtr(&__bss);
    @memset(__bss[0..bss_len], 0);
    while (true) {}
}

export fn boot() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\mv sp, %[stack_top]
        \\j kernelMain
        :
        : [stack_top] "r" (@intFromPtr(&__stack_top)),
    );
}
