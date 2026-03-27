pub var global_uart: Uart = undefined;

pub fn init(base_addr: usize) void {
    global_uart = .init(base_addr);
}

pub const Uart = struct {
    regs: [*]volatile u8,

    const Self = @This();

    const RBR = 0;
    const THR = 0;
    const IER = 1;
    const IIR = 2;
    const FCR = 2;
    const LCR = 3;
    const LSR = 5;
    const MSR = 6;
    const SCR = 7;
    const DLL = 0;
    const DLM = 1;

    fn init(base_addr: usize) Self {
        const regs: [*]volatile u8 = @ptrFromInt(base_addr);
        regs[IER] = 0x00; // disable interrupts
        regs[LCR] = 0x80; // enable DLAB
        regs[DLL] = 0x01; // set baud rate 115200 bps
        regs[DLM] = 0x00; //
        regs[LCR] = 0x03; // 8N1
        regs[FCR] = 0xc7; // enable FIFO, 14 byte threshold
        return .{
            .regs = @ptrFromInt(base_addr),
        };
    }

    pub fn putc(self: Self, c: u8) void {
        while (self.regs[LSR] & (1 << 5) == 0) {}
        self.regs[0] = c;
    }
};
