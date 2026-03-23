export fn _start() callconv(.c) void {
    while (true) {
        asm volatile ("ecall");
        for (0..200_000_000) |_| asm volatile ("nop");
    }
}
