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

const PageAllocator = mame.mem.PageAllocator;
const SlabAllocator = mame.mem.SlabAllocator;
const PageTable = mame.page.PageTable;
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
    const entry: u64 = @bitCast(Lv2Entry.newMapPage(0x8000_0000, true, .read_write_execute, false));
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

const user_bin = @embedFile("user.elf");

var page_allocator: PageAllocator = undefined;
var slab_allocator: SlabAllocator = undefined;

fn kernelMain() !void {
    const bss_len = @intFromPtr(&__bss_end) - @intFromPtr(&__bss);
    @memset(@as([*]u8, @ptrCast(&__bss))[0..bss_len], 0);

    mame.trap.init();

    const memory_len = 64 * 1024 * 1024;
    const free_ram_addr = pa2va(symbol2pa(@intFromPtr(&__free_ram_start)));
    const memory: [*]align(4096) u8 = @ptrFromInt(free_ram_addr);

    page_allocator = PageAllocator.init(memory[0..memory_len]);
    slab_allocator = SlabAllocator.init(&page_allocator);
    const allocator = slab_allocator.allocator();

    const page_table = try PageTable.new(&page_allocator);
    // .text (read_execute)
    try mapRange(
        page_table,
        &page_allocator,
        @intFromPtr(&__text_start),
        @intFromPtr(&__text_end),
        .read_execute,
    );
    // .rodata (read_only)
    try mapRange(
        page_table,
        &page_allocator,
        @intFromPtr(&__rodata_start),
        @intFromPtr(&__rodata_end),
        .read_only,
    );
    // .data & .bss (read_write)
    try mapRange(
        page_table,
        &page_allocator,
        @intFromPtr(&__data_start),
        @intFromPtr(&__data_end),
        .read_write,
    );
    // stack (read_write)
    try mapRange(
        page_table,
        &page_allocator,
        @intFromPtr(&__stack_start),
        @intFromPtr(&__stack_end),
        .read_write,
    );

    // map whole memory
    const ram_start = 0xFFFF_FFC0_8000_0000;
    const total_ram_size = 128 * 1024 * 1024;
    try mapRange(
        page_table,
        &page_allocator,
        ram_start,
        ram_start + total_ram_size,
        .read_write,
    );

    mame.page.enablePaging(page_table.root_paddr);
    log.info("Mapped kernel memory", .{});

    timer.init(allocator);

    am.enableGlobalInterrupt();
    am.enableTimerInterrupt();
    sbi.timer.set(am.getTime() + 100_000);

    try process.init(&page_allocator, allocator);
    try process.global_manager.spawnKernel(@intFromPtr(&procAEntry));
    try process.global_manager.spawnKernel(@intFromPtr(&procBEntry));
    process.global_manager.spawnUser(user_bin) catch {
        log.err("user process error!", .{});
    };

    while (true) {
        asm volatile ("wfi");
        process.global_manager.cleanupZombies();
    }
}

fn mapRange(page_table: PageTable, allocator: *PageAllocator, start_vaddr: usize, end_vaddr: usize, perm: Permission) !void {
    try page_table.mapRange(allocator, start_vaddr, va2pa(start_vaddr), end_vaddr - start_vaddr, perm, false);
}

export fn trampoline() noreturn {
    kernelMain() catch |err| {
        log.err("kernelMain error: {}", .{err});
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
        \\la sp, __stack_top
        \\add sp, sp, t2
        \\la t0, trampoline
        \\add t0, t0, t2
        \\
        \\jr t0
        :
        : [kernel_offset] "i" (mame.page.KERNEL_BIN_OFFSET),
        : .{ .memory = true });
}
