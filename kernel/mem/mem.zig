const std = @import("std");
const log = std.log.scoped(.mem);
const Allocator = std.mem.Allocator;

pub const PageAllocator = @import("PageAllocator.zig");
pub const SlabAllocator = @import("SlabAllocator.zig");

pub const Phys = usize;
pub const Virt = usize;

pub var page_allocator: PageAllocator = undefined;

pub fn init(memory: []align(4096) u8) void {
    page_allocator = .init(memory);
}
