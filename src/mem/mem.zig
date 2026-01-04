const std = @import("std");
const log = std.log.scoped(.mem);
const Allocator = std.mem.Allocator;

const PageAllocator = @import("PageAllocator.zig");

var page_allocator_instance: PageAllocator = undefined;
pub fn initPageAllocator(memory: [*]align(4096) u8, len: usize) PageAllocator {
    page_allocator_instance = PageAllocator.init(memory, len);
    return page_allocator_instance;
}
