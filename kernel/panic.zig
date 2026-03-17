const std = @import("std");
const builtin = std.builtin;
const log = std.log.scoped(.panic);

pub fn panic_fn(msg: []const u8, _: ?*builtin.StackTrace, _: ?usize) noreturn {
    @branchHint(.cold);
    log.err("{s}", .{msg});

    log.err("=== Stack Trace ===", .{});
    var it = std.debug.StackIterator.init(@returnAddress(), null);
    defer it.deinit();
    var i: usize = 0;
    while (it.next()) |frame| : (i += 1) {
        log.err("#{d:0>2}: 0x{X:0>16}", .{ i, frame });
    }

    while (true) asm volatile ("wfi");
}
