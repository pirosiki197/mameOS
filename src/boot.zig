const std = @import("std");
const log = std.log.scoped(.boot);

const mame = @import("mame");
const klog = mame.klog;
const sbi = mame.sbi;

extern const __stack_top: anyopaque;
extern var __bss: anyopaque;
extern const __bss_end: anyopaque;
extern var __free_ram: anyopaque;
extern const __free_ram_end: anyopaque;

pub const std_options = klog.default_log_options;
pub const panic = mame.panic.panic_fn;

fn kernelMain() !void {
    const bss_len = @intFromPtr(&__bss_end) - @intFromPtr(&__bss);
    @memset(@as([*]u8, @ptrCast(&__bss))[0..bss_len], 0);

    mame.trap.init();

    log.info("booted!", .{});
    const memory_len = @intFromPtr(&__free_ram_end) - @intFromPtr(&__free_ram);

    var page_allocator = mame.mem.initPageAllocator(@ptrCast(@alignCast(&__free_ram)), memory_len);
    const allocator = page_allocator.allocator();
    const buf = allocator.alloc(u8, 128) catch {
        @panic("failed to alloc");
    };
    const message = try std.fmt.bufPrint(buf, "hello, world", .{});
    log.info("message: {s} {*}", .{ message, message.ptr });
    allocator.free(buf);

    while (true) asm volatile ("wfi");
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
