const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const PageAllocator = @import("PageAllocator.zig");
const LinkedList = std.SinglyLinkedList;

page_allocator: *PageAllocator,
list_heads: [bin_sizes.len]LinkedList = @splat(.{}),

const Self = @This();

const bin_sizes = [_]usize{
    0x20, 0x40, 0x80, 0x100, 0x200, 0x400, 0x800,
};

comptime {
    if (bin_sizes[bin_sizes.len - 1] > 4096) {
        @compileError("The largest bin size exceeds a 4KiB page size.");
    }
    if (@sizeOf(LinkedList.Node) > bin_sizes[0]) {
        @compileError("The smallest bin size exceeds the size of ChunkMetaNode.");
    }
}

pub fn init(page_allocator: *PageAllocator) Self {
    return .{
        .page_allocator = page_allocator,
    };
}

pub fn allocator(self: *Self) Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .free = free,
            .resize = resize,
            .remap = remap,
        },
    };
}

fn alloc(ctx: *anyopaque, n: usize, alignment: Alignment, _: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(ctx));

    if (binIndex(@max(alignment.toByteUnits(), n))) |index| {
        return self.allocFromBin(index);
    } else {
        const ret = self.page_allocator.alloc(n) catch return null;
        return @ptrCast(ret.ptr);
    }
}

fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, _: usize) void {
    const self: *Self = @ptrCast(@alignCast(ctx));

    const bin_index = binIndex(@max(alignment.toByteUnits(), memory.len));
    if (bin_index) |index| {
        self.freeToBin(index, @ptrCast(memory.ptr));
    } else {
        self.page_allocator.free(memory);
    }
}

fn resize(_: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, _: usize) bool {
    const bin_index = binIndex(memory.len) orelse return false;
    const size = bin_sizes[bin_index];
    if (!alignment.check(size)) return false;
    if (bin_index == 0) {
        return new_len <= size;
    } else {
        return bin_sizes[bin_index - 1] < new_len and new_len <= size;
    }
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, n: usize) ?[*]u8 {
    if (resize(ctx, memory, alignment, new_len, n)) {
        return memory.ptr;
    } else return null;
}

fn binIndex(size: usize) ?usize {
    for (bin_sizes, 0..) |bin_size, i| {
        if (size <= bin_size) return i;
    }
    return null;
}

fn initBinPage(self: *Self, bin_index: usize) !void {
    const new_page = try self.page_allocator.allocPages(1);
    const bin_size = bin_sizes[bin_index];

    var i: usize = 4096 / bin_size - 1;
    while (true) : (i -= 1) {
        const chunk: *LinkedList.Node = @ptrFromInt(@intFromPtr(new_page.ptr) + i * bin_size);
        self.list_heads[bin_index].prepend(chunk);
        if (i == 0) break;
    }
}

fn allocFromBin(self: *Self, bin_index: usize) ?[*]u8 {
    if (self.list_heads[bin_index].first == null) {
        self.initBinPage(bin_index) catch return null;
    }
    return @ptrCast(self.list_heads[bin_index].popFirst());
}

fn freeToBin(self: *Self, bin_index: usize, ptr: [*]u8) void {
    const chunk: *LinkedList.Node = @ptrCast(@alignCast(ptr));
    self.list_heads[bin_index].prepend(chunk);
}
