const std = @import("std");
const log = std.log.scoped(.PageAllocator);

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const Self = @This();

bitmap: BitMap = @splat(0),
base_address: usize,
total_pages: usize,

const page_size = 4096;
const page_mask: usize = (1 << 12) - 1;

const max_memory_size = 32 * 1024 * 1024; // 32MiB
const page_count = max_memory_size / 4096;

const MapLineType = u64;
const bits_per_mapline = 64;
const num_maplines = page_count / bits_per_mapline;

const BitMap = [num_maplines]MapLineType;

const PageID = u64;

const Status = enum(u1) {
    used = 0,
    unused = 1,
    inline fn from(boolean: bool) Status {
        return if (boolean) .used else .unused;
    }
};

pub fn init(memory: []align(4096) u8) Self {
    const num_pages = memory.len / page_size;
    return .{
        .base_address = @intFromPtr(memory.ptr),
        .total_pages = num_pages,
    };
}

fn pageId2Addr(self: *Self, pageId: PageID) usize {
    return self.base_address + pageId * page_size;
}

fn addr2PageId(self: *Self, addr: usize) PageID {
    return (addr - self.base_address) / page_size;
}

fn get(self: *Self, pageId: PageID) Status {
    const line_index = pageId / bits_per_mapline;
    const bit_index: u6 = @truncate(pageId % bits_per_mapline);
    return Status.from(self.bitmap[line_index] & tobit(bit_index) != 0);
}

fn set(self: *Self, pageId: PageID, status: Status) void {
    const line_index = pageId / bits_per_mapline;
    const bit_index: u6 = @truncate(pageId % bits_per_mapline);
    switch (status) {
        .used => self.bitmap[line_index] |= tobit(bit_index),
        .unused => self.bitmap[line_index] &= ~tobit(bit_index),
    }
}

fn markAllocated(self: *Self, pageId: PageID, num_pages: usize) void {
    for (0..num_pages) |i| {
        self.set(pageId + i, .used);
    }
}

fn markNotUsed(self: *Self, pageId: PageID, num_pages: usize) void {
    for (0..num_pages) |i| {
        self.set(pageId + i, .unused);
    }
}

pub fn allocPages(self: *Self, num_pages: usize) ![]align(4096) u8 {
    var count: usize = 0;
    var pageId: PageID = 0;
    while (pageId < self.total_pages) : (pageId += 1) {
        if (self.get(pageId) == .used) {
            count = 0;
        } else {
            count += 1;
        }
        if (count == num_pages) {
            const from = pageId + 1 - count;
            self.markAllocated(from, num_pages);
            const ptr: [*]align(4096) u8 = @ptrFromInt(self.pageId2Addr(from));
            return ptr[0 .. page_size * num_pages];
        }
    }

    return error.OutOfMemory;
}

pub fn free(self: *Self, memory: []u8) void {
    const address = @intFromPtr(memory.ptr) & ~page_mask;
    const pageId = self.addr2PageId(address);
    self.markNotUsed(pageId, numPages(memory.len));
}

pub fn numPages(size: usize) usize {
    return (size + page_size - 1) / page_size;
}

fn tobit(index: u6) u64 {
    return @as(u64, 1) << index;
}
