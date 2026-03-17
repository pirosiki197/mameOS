const std = @import("std");
const log = std.log.scoped(.mem);
const Allocator = std.mem.Allocator;

pub const PageAllocator = @import("PageAllocator.zig");
pub const SlabAllocator = @import("SlabAllocator.zig");

pub const Phys = usize;
pub const Virt = usize;
