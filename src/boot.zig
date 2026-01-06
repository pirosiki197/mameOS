const std = @import("std");
const log = std.log.scoped(.boot);

const Allocator = std.mem.Allocator;

const mame = @import("mame");
const am = mame.am;
const klog = mame.klog;
const sbi = mame.sbi;

const ProcessManager = mame.process.ProcessManager;
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
extern var __free_ram: anyopaque;
extern const __free_ram_end: anyopaque;

pub const std_options = klog.default_log_options;
pub const panic = mame.panic.panic_fn;

fn procAEntry() void {
    log.info("Starting process A", .{});
    while (true) {
        log.info("A", .{});
        manager.yield();
        for (0..1_000_000_000) |_| asm volatile ("nop");
    }
}

fn procBEntry() void {
    log.info("Starting process B", .{});
    while (true) {
        log.info("B", .{});
        manager.yield();
        for (0..1_000_000_000) |_| asm volatile ("nop");
    }
}

var manager: ProcessManager = undefined;

fn kernelMain() !void {
    const bss_len = @intFromPtr(&__bss_end) - @intFromPtr(&__bss);
    @memset(@as([*]u8, @ptrCast(&__bss))[0..bss_len], 0);

    mame.trap.init();

    log.info("Booted!", .{});

    const memory_len = @intFromPtr(&__free_ram_end) - @intFromPtr(&__free_ram);
    const memory: [*]align(4096) u8 = @ptrCast(@alignCast(&__free_ram));

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
    // heap (read_write)
    try mapRange(allocator, root_paddr, @intFromPtr(&__free_ram), @intFromPtr(&__free_ram_end), .read_write);
    mame.page.enablePaging(root_paddr);

    log.info("Mapped kernel memory", .{});

    am.enableGlobalInterrupt();
    am.enableTimerInterrupt();

    manager = try ProcessManager.init(allocator);
    try manager.spawn(@intFromPtr(&procAEntry));
    try manager.spawn(@intFromPtr(&procBEntry));

    while (true) {
        manager.yield();
        for (0..1_000_000_000) |_| asm volatile ("nop");
        log.info("Back in kernelMain", .{});
    }

    while (true) asm volatile ("wfi");
}

fn mapRange(allocator: Allocator, root_paddr: usize, start_paddr: usize, end_paddr: usize, perm: Permission) !void {
    var paddr = start_paddr;
    while (paddr < end_paddr) : (paddr += 4096) {
        try mame.page.map4kTo(allocator, root_paddr, paddr, paddr, perm);
    }
}

export fn trampoline() noreturn {
    kernelMain() catch {
        @panic("Exiting...");
    };
    unreachable;
}

export fn boot() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\mv sp, %[stack_top]
        \\j trampoline
        :
        : [stack_top] "r" (@intFromPtr(&__stack_top)),
    );
}
