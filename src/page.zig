const std = @import("std");
const mame = @import("mame");
const am = mame.am;

const PageAllocator = mame.mem.PageAllocator;
const Alignment = std.mem.Alignment;
const Phys = mame.mem.Phys;
const Virt = mame.mem.Virt;

pub const KERNEL_BIN_OFFSET = 0xFFFF_FFFF_0000_0000;
pub const DIRECT_MAP_OFFSET = 0xFFFF_FFC0_0000_0000;

pub fn pa2va(paddr: usize) usize {
    return paddr +% DIRECT_MAP_OFFSET;
}
pub fn va2pa(vaddr: usize) usize {
    const offset: usize = if (vaddr >= KERNEL_BIN_OFFSET) KERNEL_BIN_OFFSET else DIRECT_MAP_OFFSET;
    return vaddr -% offset;
}
pub fn symbol2pa(vaddr: usize) usize {
    return vaddr -% KERNEL_BIN_OFFSET;
}

const Level = enum { lv2, lv1, lv0 };
pub const Permission = enum(u3) {
    read_only = 0b001,
    execute_only = 0b100,
    read_write = 0b011,
    read_execute = 0b101,
    read_write_execute = 0b111,

    fn read(self: Permission) bool {
        return (@intFromEnum(self) & 0b001) != 0;
    }
    fn write(self: Permission) bool {
        return (@intFromEnum(self) & 0b010) != 0;
    }
    fn execute(self: Permission) bool {
        return (@intFromEnum(self) & 0b100) != 0;
    }
};
const page_size = 4096;
const page_shift = 12;
const page_mask: usize = (1 << page_shift) - 1;

const num_table_entries = 512;

fn EntryBase(table_level: Level) type {
    return packed struct(u64) {
        const Self = @This();
        const level = table_level;
        const LowerType = switch (level) {
            .lv2 => Lv1Entry,
            .lv1 => Lv0Entry,
            .lv0 => struct {},
        };

        valid: bool = true,
        read: bool,
        write: bool,
        execute: bool,
        user: bool,
        global: bool = false,
        accessed: bool = false,
        dirty: bool = false,
        rsw: u2 = 0,
        ppn: u44,
        _reserved: u10 = 0,

        pub fn newMapPage(paddr: usize, valid: bool, perm: Permission, user: bool) Self {
            return Self{
                .valid = valid,
                .read = perm.read(),
                .write = perm.write(),
                .execute = perm.execute(),
                .user = user,
                .ppn = @truncate(paddr >> page_shift),
            };
        }

        fn newMapTable(table_paddr: Phys, valid: bool) Self {
            if (level == .lv0) @compileError("Lv0 entry cannot reference a page table");
            return Self{
                .valid = valid,
                .read = false,
                .write = false,
                .execute = false,
                .user = false,
                .ppn = @truncate(table_paddr >> page_shift),
            };
        }

        fn address(self: Self) usize {
            return @as(usize, @intCast(self.ppn)) << page_shift;
        }
    };
}

pub const Lv2Entry = EntryBase(.lv2);
const Lv1Entry = EntryBase(.lv1);
const Lv0Entry = EntryBase(.lv0);

pub fn enablePaging(root_paddr: Phys) void {
    const satp = am.Satp{
        .mode = 8, // Sv39
        .ppn = @truncate(root_paddr >> page_shift),
    };
    satp.load();
    am.clearTLBCache();
}

fn getEntry(T: type, vaddr: Virt, paddr: Phys) *T {
    const table = getTable(T, paddr);
    const shift = switch (T) {
        Lv2Entry => 30,
        Lv1Entry => 21,
        Lv0Entry => 12,
        else => @compileError("unknown type"),
    };
    return &table[(vaddr >> shift) & 0x1FF];
}

fn getTable(T: type, paddr: Phys) []T {
    const ptr: [*]T = @ptrFromInt(pa2va(paddr & ~page_mask));
    return ptr[0..num_table_entries];
}

fn allocateNewTable(T: type, entry: *T, allocator: *PageAllocator) !void {
    const page = try allocator.allocPages(1);
    @memset(page, 0);
    entry.* = T.newMapTable(va2pa(@intFromPtr(page.ptr)), true);
}

pub const PageTable = struct {
    root_paddr: Phys,

    pub fn new(allocator: *PageAllocator) !PageTable {
        const page = try allocator.allocPages(1);
        @memset(page, 0);
        return .{
            .root_paddr = va2pa(@intFromPtr(page.ptr)),
        };
    }

    pub fn newProcessTable(allocator: *PageAllocator) !PageTable {
        const page_table = try PageTable.new(allocator);
        const root_table = getTable(Lv2Entry, page_table.root_paddr);

        const current_root = am.Satp.store().ppn << 12;
        const src_table = getTable(Lv2Entry, current_root);

        @memcpy(root_table[256..512], src_table[256..512]);

        return page_table;
    }

    pub fn fromActualSatp() PageTable {
        return .{ .root_paddr = am.readSatp().ppn << 12 };
    }

    pub fn map(self: PageTable, allocator: *PageAllocator, v: Virt, p: Phys, perm: Permission, user: bool) !void {
        const lv2ent = getEntry(Lv2Entry, v, self.root_paddr);
        if (!lv2ent.valid) try allocateNewTable(Lv2Entry, lv2ent, allocator);

        const lv1ent = getEntry(Lv1Entry, v, lv2ent.address());
        if (!lv1ent.valid) try allocateNewTable(Lv1Entry, lv1ent, allocator);

        const lv0ent = getEntry(Lv0Entry, v, lv1ent.address());
        if (lv0ent.valid) return error.AlreadyMapped;
        const new_lv0ent = Lv0Entry.newMapPage(p, true, perm, user);
        lv0ent.* = new_lv0ent;
    }

    pub fn mapRange(self: PageTable, allocator: *PageAllocator, v_start: Virt, p_start: Phys, size: usize, perm: Permission, user: bool) !void {
        var offset: usize = 0;
        while (offset < size) : (offset += page_size) {
            try self.map(allocator, v_start + offset, p_start + offset, perm, user);
        }
    }
};
