const std = @import("std");
const log = std.log.scoped(.boot);

const Allocator = std.mem.Allocator;

const mame = @import("mame");
const am = mame.am;
const klog = mame.klog;
const process = mame.process;
const sbi = mame.sbi;
const timer = mame.timer;

const va2pa = mame.page.va2pa;
const pa2va = mame.page.pa2va;
const symbol2pa = mame.page.symbol2pa;

const Lv2Entry = mame.page.Lv2Entry;
const ProcessManager = mame.process.Scheduler;
const Permission = mame.page.Permission;

extern const __kernel_base: anyopaque;
extern const __text_start: anyopaque;
extern const __text_end: anyopaque;
extern const __rodata_start: anyopaque;
extern const __rodata_end: anyopaque;
extern const __data_start: anyopaque;
extern const __data_end: anyopaque;
extern const __stack_start: anyopaque;
extern const __stack_end: anyopaque;
extern const __stack_top: anyopaque;
extern var __bss: anyopaque;
extern const __bss_end: anyopaque;
extern var __free_ram_start: anyopaque;

pub const std_options = klog.default_log_options;
pub const panic = mame.panic.panic_fn;

export var boot_page_table: [512]u64 align(4096) = blk: {
    const entry: u64 = @bitCast(Lv2Entry.newMapPage(0x8000_0000, true, .read_write_execute));
    var table: [512]u64 = @splat(0);
    table[2] = entry; // 0x8000_0000
    table[258] = entry; // 0xFFFF_FFC0_8000_0000
    table[510] = entry; // 0xFFFF_FFFF_8000_0000
    break :blk table;
};

fn procAEntry() void {
    log.info("Starting process A", .{});
    for (0..3) |_| {
        log.info("A", .{});
        process.sleep(30_000_000);
    }
}

fn procBEntry() void {
    log.info("Starting process B", .{});
    while (true) {
        log.info("B", .{});
        process.sleep(10_000_000);
    }
}

fn kernelMain() !void {
    const bss_len = @intFromPtr(&__bss_end) - @intFromPtr(&__bss);
    @memset(@as([*]u8, @ptrCast(&__bss))[0..bss_len], 0);

    mame.trap.init();

    const memory_len = 128 * 1024 * 1024;
    const free_ram_addr = pa2va(symbol2pa(@intFromPtr(&__free_ram_start)));
    const free_ram_end_addr = free_ram_addr + memory_len;
    const memory: [*]align(4096) u8 = @ptrFromInt(free_ram_addr);

    var page_allocator = mame.mem.initPageAllocator(memory[0..memory_len]);
    const allocator = page_allocator.allocator();

    const root_paddr = try mame.page.setupLv2Table(allocator);
    // .text (read_execute)
    try mapRange(allocator, root_paddr, @intFromPtr(&__text_start), @intFromPtr(&__text_end), .read_execute);
    // .rodata (read_only)
    try mapRange(allocator, root_paddr, @intFromPtr(&__rodata_start), @intFromPtr(&__rodata_end), .read_only);
    // .data & .bss (read_write)
    try mapRange(allocator, root_paddr, @intFromPtr(&__data_start), @intFromPtr(&__data_end), .read_write);
    // stack (read_write)
    try mapRange(allocator, root_paddr, @intFromPtr(&__stack_start), @intFromPtr(&__stack_end), .read_write);
    // ram (read_write)
    try mapRange(allocator, root_paddr, free_ram_addr, free_ram_end_addr, .read_write);
    mame.page.enablePaging(root_paddr);

    log.info("Mapped kernel memory", .{});

    timer.init(allocator);

    am.enableGlobalInterrupt();
    am.enableTimerInterrupt();
    sbi.timer.set(am.getTime() + 100_000);

    try process.init(allocator);
    try process.global_scheduler.spawn(@intFromPtr(&procAEntry));
    try process.global_scheduler.spawn(@intFromPtr(&procBEntry));

    while (true) asm volatile ("wfi");
}

fn mapRange(allocator: Allocator, root_paddr: usize, start_paddr: usize, end_paddr: usize, perm: Permission) !void {
    var vaddr = start_paddr;
    while (vaddr < end_paddr) : (vaddr += 4096) {
        try mame.page.map4kTo(allocator, root_paddr, vaddr, va2pa(vaddr), perm);
    }
}

fn trampoline() noreturn {
    kernelMain() catch {
        @panic("Exiting...");
    };
    unreachable;
}

export fn boot() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\
        // prepare page table
        \\la t0, boot_page_table
        \\srli t0, t0, 12
        // Mode = Sv39
        \\li t1, 8 << 60
        \\or t0, t0, t1
        \\csrw satp, t0
        \\sfence.vma
        \\
        \\li t2, %[kernel_offset]
        \\mv sp, %[stack_top]
        \\add sp, sp, t2
        \\mv t0, %[trampoline]
        \\add t0, t0, t2
        \\jr t0
        :
        : [kernel_offset] "i" (mame.page.KERNEL_BIN_OFFSET),
          [stack_top] "r" (@intFromPtr(&__stack_top)),
          [trampoline] "r" (@intFromPtr(&trampoline)),
    );
}
