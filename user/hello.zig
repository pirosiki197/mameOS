const std = @import("std");

export fn start() linksection(".text.start") callconv(.c) void {
    main() catch exit(1);
    exit(0);
}

fn main() !void {
    var sbrk_allocator = SbrkAllocator{};
    const allocator = sbrk_allocator.allocator();

    var map = std.AutoHashMap(u32, u32).init(allocator);
    defer map.deinit();

    try map.put(34, 32);
    const out = try std.fmt.allocPrint(
        allocator,
        "map[{d}]={d}\n",
        .{ 34, map.get(34).? },
    );
    for (out) |c| {
        putchar(c);
    }
}

fn putchar(c: u8) void {
    asm volatile ("ecall"
        :
        : [char] "{a0}" (c),
          [id] "{a7}" (1),
    );
}

fn exit(code: usize) void {
    asm volatile ("ecall"
        :
        : [arg] "{a0}" (code),
          [id] "{a7}" (2),
    );
    while (true) {}
}

const SbrkAllocator = struct {
    const Allocator = std.mem.Allocator;
    const Alignment = std.mem.Alignment;

    fn allocator(self: *SbrkAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .free = Allocator.noFree,
                .resize = Allocator.noResize,
                .remap = Allocator.noRemap,
            },
        };
    }

    fn alloc(_: *anyopaque, size: usize, alignment: Alignment, _: usize) ?[*]u8 {
        const current_addr: usize = asm volatile ("ecall"
            : [ptr] "={a0}" (-> usize),
            : [size] "{a0}" (0),
              [id] "{a7}" (12),
        );
        const aligned_addr = alignment.forward(current_addr);

        const ret: isize = asm volatile ("ecall"
            : [ret] "={a0}" (-> isize),
            : [size] "{a0}" (size + aligned_addr - current_addr),
              [id] "{a7}" (12),
        );
        if (ret < 0) {
            return null;
        }

        return @as([*]u8, @ptrFromInt(aligned_addr));
    }
};
