pub fn clearTLBCache() void {
    asm volatile ("sfence.vma" ::: .{ .memory = true });
}

pub const Satp = packed struct(u64) {
    mode: u4,
    asid: u16 = 0,
    ppn: u44,

    pub fn load(self: Satp) void {
        asm volatile ("csrw satp, %[satp]"
            :
            : [satp] "r" (self),
        );
    }
};
