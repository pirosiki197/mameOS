pub fn clearTLBCache() void {
    asm volatile ("sfence.vma" ::: .{ .memory = true });
}

pub const Satp = packed struct(u64) {
    ppn: u44,
    asid: u16 = 0,
    mode: u4,

    pub fn load(self: Satp) void {
        asm volatile ("csrw satp, %[satp]"
            :
            : [satp] "r" (self),
        );
    }
};

pub const Sstatus = packed struct(u64) {
    _ignore1: u1 = 0,
    sie: bool = false,
    _ignore2: u3 = 0,
    /// supervisor previous interrupt enable
    spie: bool,
    ube: bool = false,
    _ignore3: u1 = 0,
    /// supervisor previsous plivilege
    spp: u1,
    _ignore: u55 = 0,
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
