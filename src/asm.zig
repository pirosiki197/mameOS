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

pub fn getTime() u64 {
    return asm volatile ("csrr %[time], time"
        : [time] "=r" (-> u64),
    );
}

pub fn enableGlobalInterrupt() void {
    asm volatile ("csrs sstatus, %[val]"
        :
        : [val] "r" (1 << 1),
    );
}

pub fn enableTimerInterrupt() void {
    asm volatile ("csrs sie, %[val]"
        :
        : [val] "r" (1 << 5),
    );
}
