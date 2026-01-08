const std = @import("std");
const log = std.log.scoped(.trap);

const mame = @import("mame");
const am = mame.am;
const process = mame.process;
const timer = mame.timer;

pub fn init() void {
    const addr = @intFromPtr(&trapEntry);
    asm volatile ("csrw stvec, %[trapEntry]"
        :
        : [trapEntry] "r" (addr),
    );
}

const TrapCause = enum(usize) {
    const interrupt_mask = 1 << (8 * @sizeOf(usize) - 1);

    instruction_address_misaligned = 0,
    instruction_access_fault = 1,
    illegal_instruction = 2,
    breakpoint = 3,
    load_address_misaligned = 4,
    load_access_fault = 5,
    store_amo_address_misaligned = 6,
    store_amo_access_fault = 7,
    environment_call_from_u_mode = 8,
    environment_call_from_s_mode = 9,
    instruction_page_fault = 12,
    load_page_fault = 13,
    store_amo_page_fault = 15,
    software_check = 18,
    hardware_error = 19,

    supervisor_software_interrupt = interrupt_mask | 1,
    supervisor_timer_interrupt = interrupt_mask | 5,
    supervisor_external_interrupt = interrupt_mask | 9,
    counter_overflow_interrupt = interrupt_mask | 13,

    _,
};

pub const TrapFrame = packed struct {
    ra: usize,
    gp: usize,
    tp: usize,
    t0: usize,
    t1: usize,
    t2: usize,
    t3: usize,
    t4: usize,
    t5: usize,
    t6: usize,
    a0: usize,
    a1: usize,
    a2: usize,
    a3: usize,
    a4: usize,
    a5: usize,
    a6: usize,
    a7: usize,
    s0: usize,
    s1: usize,
    s2: usize,
    s3: usize,
    s4: usize,
    s5: usize,
    s6: usize,
    s7: usize,
    s8: usize,
    s9: usize,
    s10: usize,
    s11: usize,
    sepc: usize,
    sstatus: usize,

    fn dump(self: *TrapFrame) void {
        const fields = @typeInfo(TrapFrame).@"struct".fields;
        inline for (fields) |field| {
            log.err("{s: <7} = 0x{X:0>16}", .{ field.name, @field(self, field.name) });
        }
    }
};

export fn handleTrap(frame: *TrapFrame) void {
    const scause: TrapCause = blk: {
        const scause_val = asm volatile ("csrr %[val], scause"
            : [val] "=r" (-> usize),
        );
        break :blk @enumFromInt(scause_val);
    };
    const stval = asm volatile ("csrr %[val], stval"
        : [val] "=r" (-> usize),
    );
    switch (scause) {
        .supervisor_timer_interrupt => {
            log.debug("Tick!", .{});
            const time = am.getTime();
            mame.sbi.timer.set(time + 100_000);
            process.global_manager.yield();
            // timer.global_manager.tick(time);
        },
        else => {
            log.err("unexpected trap: scause={s} stval=0x{x}", .{ @tagName(scause), stval });
            frame.dump();
            @panic("panic!!!");
        },
    }
}

fn trapEntry() align(4) callconv(.naked) void {
    asm volatile (
        \\addi sp, sp, -8 * 32
        \\sd ra,  8 * 0(sp)
        \\sd gp,  8 * 1(sp)
        \\sd tp,  8 * 2(sp)
        \\sd t0,  8 * 3(sp)
        \\sd t1,  8 * 4(sp)
        \\sd t2,  8 * 5(sp)
        \\sd t3,  8 * 6(sp)
        \\sd t4,  8 * 7(sp)
        \\sd t5,  8 * 8(sp)
        \\sd t6,  8 * 9(sp)
        \\sd a0,  8 * 10(sp)
        \\sd a1,  8 * 11(sp)
        \\sd a2,  8 * 12(sp)
        \\sd a3,  8 * 13(sp)
        \\sd a4,  8 * 14(sp)
        \\sd a5,  8 * 15(sp)
        \\sd a6,  8 * 16(sp)
        \\sd a7,  8 * 17(sp)
        \\sd s0,  8 * 18(sp)
        \\sd s1,  8 * 19(sp)
        \\sd s2,  8 * 20(sp)
        \\sd s3,  8 * 21(sp)
        \\sd s4,  8 * 22(sp)
        \\sd s5,  8 * 23(sp)
        \\sd s6,  8 * 24(sp)
        \\sd s7,  8 * 25(sp)
        \\sd s8,  8 * 26(sp)
        \\sd s9,  8 * 27(sp)
        \\sd s10, 8 * 28(sp)
        \\sd s11, 8 * 29(sp)
        \\
        \\csrr t0, sepc
        \\sd t0, 8 * 30(sp)
        \\csrr t0, sstatus
        \\sd t0, 8 * 31(sp)
        \\
        \\mv a0, sp
        \\call handleTrap
        \\
        \\.global kernel_target
        \\kernel_target:
        \\ld ra,  8 * 0(sp)
        \\ld gp,  8 * 1(sp)
        \\ld tp,  8 * 2(sp)
        \\ld t0,  8 * 3(sp)
        \\ld t1,  8 * 4(sp)
        \\ld t2,  8 * 5(sp)
        \\ld t3,  8 * 6(sp)
        \\ld t4,  8 * 7(sp)
        \\ld t5,  8 * 8(sp)
        \\ld t6,  8 * 9(sp)
        \\ld a0,  8 * 10(sp)
        \\ld a1,  8 * 11(sp)
        \\ld a2,  8 * 12(sp)
        \\ld a3,  8 * 13(sp)
        \\ld a4,  8 * 14(sp)
        \\ld a5,  8 * 15(sp)
        \\ld a6,  8 * 16(sp)
        \\ld a7,  8 * 17(sp)
        \\ld s0,  8 * 18(sp)
        \\ld s1,  8 * 19(sp)
        \\ld s2,  8 * 20(sp)
        \\ld s3,  8 * 21(sp)
        \\ld s4,  8 * 22(sp)
        \\ld s5,  8 * 23(sp)
        \\ld s6,  8 * 24(sp)
        \\ld s7,  8 * 25(sp)
        \\ld s8,  8 * 26(sp)
        \\ld s9,  8 * 27(sp)
        \\ld s10, 8 * 28(sp)
        \\ld s11, 8 * 29(sp)
        \\
        \\ld t0, 8 * 30(sp)
        \\csrw sepc, t0
        \\ld t0, 8 * 31(sp)
        \\csrw sstatus, t0
        \\
        \\addi sp, sp, 8 * 32
        \\sret
    );
}
