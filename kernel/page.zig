const std = @import("std");
const mame = @import("mame");
const am = mame.am;

const Alignment = std.mem.Alignment;
const Phys = mame.mem.Phys;
const Virt = mame.mem.Virt;

const allocator = &mame.mem.page_allocator;

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
pub const Permission = packed struct(u3) {
    r: bool = false,
    w: bool = false,
    x: bool = false,

    pub const read_only: Permission = .{ .r = true };
    pub const read_write: Permission = .{ .r = true, .w = true };
    pub const read_execute: Permission = .{ .r = true, .x = true };
    pub const read_write_execute: Permission = .{ .r = true, .w = true, .x = true };
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
        _reserved: u7 = 0,
        pbmt: MemoryType = .pma,
        n: u1 = 0,

        const MemoryType = enum(u2) {
            pma = 0,
            nc = 1,
            io = 2,
        };

        pub fn newMapPage(paddr: usize, valid: bool, perm: Permission, user: bool, memory_type: MemoryType) Self {
            return Self{
                .valid = valid,
                .read = perm.r,
                .write = perm.w,
                .execute = perm.x,
                .user = user,
                .ppn = @truncate(paddr >> page_shift),
                .pbmt = memory_type,
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

        fn isLeaf(self: Self) bool {
            return self.read or self.write or self.execute;
        }

        fn isTable(self: Self) bool {
            return self.valid and !self.isLeaf();
        }

        fn address(self: Self) Phys {
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

fn allocateNewTable(T: type, entry: *T) !void {
    const page = try allocator.allocPages(1);
    @memset(page, 0);
    entry.* = T.newMapTable(va2pa(@intFromPtr(page.ptr)), true);
}

pub const PageTable = struct {
    root_paddr: Phys,

    pub fn new() !PageTable {
        const page = try allocator.allocPages(1);
        @memset(page, 0);
        return .{
            .root_paddr = va2pa(@intFromPtr(page.ptr)),
        };
    }

    pub fn newProcessTable() !PageTable {
        const page_table = try PageTable.new();
        const root_table = getTable(Lv2Entry, page_table.root_paddr);

        const current_table = PageTable.fromActualSatp();
        const src_table = getTable(Lv2Entry, current_table.root_paddr);
        // copy kernel page table
        @memcpy(root_table[256..512], src_table[256..512]);

        return page_table;
    }

    pub fn fromActualSatp() PageTable {
        return .{ .root_paddr = am.Satp.store().ppn << 12 };
    }

    pub fn deinit(self: PageTable) void {
        const table = getTable(Lv2Entry, self.root_paddr);

        for (table[0..255]) |e| {
            if (!e.valid) continue;
            freeLv1Table(e.address());
        }

        allocator.free(std.mem.sliceAsBytes(table));
    }

    fn freeLv1Table(table_paddr: Phys) void {
        const table = getTable(Lv1Entry, table_paddr);

        for (table) |e| {
            if (!e.valid) continue;
            freeLv0Table(e.address());
        }

        allocator.free(std.mem.sliceAsBytes(table));
    }

    fn freeLv0Table(table_paddr: Phys) void {
        const table = getTable(Lv0Entry, table_paddr);

        for (table) |e| {
            if (!e.valid) continue;

            const memory: [*]u8 = @ptrFromInt(pa2va(e.address()));
            allocator.free(memory[0..page_size]);
        }

        allocator.free(std.mem.sliceAsBytes(table));
    }

    pub fn map(self: PageTable, v: Virt, p: Phys, perm: Permission, user: bool) !void {
        const lv2ent = getEntry(Lv2Entry, v, self.root_paddr);
        if (!lv2ent.valid) try allocateNewTable(Lv2Entry, lv2ent);

        const lv1ent = getEntry(Lv1Entry, v, lv2ent.address());
        if (!lv1ent.valid) try allocateNewTable(Lv1Entry, lv1ent);

        const lv0ent = getEntry(Lv0Entry, v, lv1ent.address());
        if (lv0ent.valid) return error.AlreadyMapped;
        const new_lv0ent = Lv0Entry.newMapPage(
            p,
            true,
            perm,
            user,
            .pma,
        );
        lv0ent.* = new_lv0ent;
    }

    pub fn mapIo(self: PageTable, v: Virt, p: Phys) !void {
        const lv2ent = getEntry(Lv2Entry, v, self.root_paddr);
        if (!lv2ent.valid) try allocateNewTable(Lv2Entry, lv2ent);

        const lv1ent = getEntry(Lv1Entry, v, lv2ent.address());
        if (!lv1ent.valid) try allocateNewTable(Lv1Entry, lv1ent);

        const lv0ent = getEntry(Lv0Entry, v, lv1ent.address());
        if (lv0ent.valid) return error.AlreadyMapped;
        const new_lv0ent = Lv0Entry.newMapPage(
            p,
            true,
            .read_write,
            false,
            .io,
        );
        lv0ent.* = new_lv0ent;
    }

    pub fn mapRange(self: PageTable, v_start: Virt, p_start: Phys, size: usize, perm: Permission, user: bool) !void {
        var offset: usize = 0;
        while (offset < size) : (offset += page_size) {
            try self.map(v_start + offset, p_start + offset, perm, user);
        }
    }

    pub fn mapMemory(self: PageTable, v_start: Virt, memory: []u8, perm: Permission, user: bool) !void {
        return mapRange(self, v_start, va2pa(@intFromPtr(memory.ptr)), memory.len, perm, user);
    }
};
