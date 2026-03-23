export fn start() linksection(".text.start") callconv(.c) void {
    main();
    exit(0);
}

fn main() void {
    for (0..2) |_| {
        for ("hello, world\n") |c| {
            putchar(c);
        }
    }
}

fn putchar(c: u8) void {
    asm volatile ("ecall"
        :
        : [char] "{a0}" (c),
          [id] "{a7}" (1),
    );
}

fn exit(code: usize) void {
    asm volatile ("ecall"
        :
        : [arg] "{a0}" (code),
          [id] "{a7}" (2),
    );
    while (true) {}
}
