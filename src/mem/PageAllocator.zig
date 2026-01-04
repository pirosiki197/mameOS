const std = @import("std");
const log = std.log.scoped(.page_allocator);
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

data: [*]align(4096) u8,
head: ?*Node,

const Self = @This();
const page_size = 4096;

pub const vtable = Allocator.VTable{
    .alloc = alloc,
    .free = free,
    .resize = resize,
    .remap = remap,
};

const Node = struct {
    next: ?*Node,
    block_size: usize,
};

pub fn init(memory: [*]align(4096) u8, len: usize) Self {
    var head: *Node = @ptrCast(memory);
    head.next = null;
    head.block_size = len;
    return .{ .data = memory, .head = head };
}

pub fn allocator(self: *Self) Allocator {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

fn alloc(_self: *anyopaque, len: usize, _: Alignment, _: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(_self));

    const page_num = (len + page_size - 1) / page_size;
    const required_len = page_size * page_num;

    var opt_node = self.head;
    var prev_node: ?*Node = null;
    while (opt_node) |node| {
        if (node.block_size >= required_len) break;
        prev_node = node;
        opt_node = node.next;
    }
    const node = opt_node orelse return null;

    if (node.block_size == required_len) {
        if (prev_node) |prev| {
            prev.next = node.next;
        } else {
            self.head = node.next;
        }
    } else {
        const new_node: *Node = @ptrFromInt(@as(usize, @intFromPtr(node)) + required_len);
        new_node.next = node.next;
        new_node.block_size = node.block_size - required_len;
        if (prev_node) |prev| {
            prev.next = new_node;
        } else {
            self.head = new_node;
        }
    }

    return @ptrCast(node);
}

fn free(_self: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
    const self: *Self = @ptrCast(@alignCast(_self));

    const page_num = (memory.len + page_size - 1) / page_size;
    const freed_len = page_size * page_num;

    const freed_node: *Node = @ptrCast(@alignCast(memory.ptr));
    freed_node.block_size = freed_len;
    freed_node.next = null;

    var opt_node = self.head;
    var prev_node: ?*Node = null;
    while (opt_node) |node| {
        if (@intFromPtr(memory.ptr) < @intFromPtr(node)) {
            break;
        }
        prev_node = node;
        opt_node = node.next;
    }

    freed_node.next = opt_node;

    const current_node = if (prev_node) |prev| blk: {
        if (@intFromPtr(prev) + prev.block_size == @intFromPtr(freed_node)) {
            prev.next = freed_node.next;
            prev.block_size += freed_len;
            break :blk prev;
        } else {
            prev.next = freed_node;
            break :blk freed_node;
        }
    } else blk: {
        self.head = freed_node;
        break :blk freed_node;
    };
    if (current_node.next) |next_node| {
        if (@intFromPtr(current_node) + current_node.block_size == @intFromPtr(next_node)) {
            current_node.next = next_node.next;
            current_node.block_size += next_node.block_size;
        }
    }
}

fn resize(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) bool {
    @panic("FreeListAllocator does not support resizing.");
}
fn remap(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) ?[*]u8 {
    @panic("FreeListAllocator does not support remapping.");
}
