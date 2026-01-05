const std = @import("std");
const mame = @import("mame");
const am = mame.am;

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

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

        fn newMapPage(paddr: usize, valid: bool, perm: Permission) Self {
            return Self{
                .valid = valid,
                .read = perm.read(),
                .write = perm.write(),
                .execute = perm.execute(),
                .user = false,
                .ppn = @truncate(paddr >> page_shift),
            };
        }

        fn newMapTable(table: [*]LowerType, valid: bool) Self {
            if (level == .lv0) @compileError("Lv0 entry cannot reference a page table");
            return Self{
                .valid = valid,
                .read = false,
                .write = false,
                .execute = false,
                .user = false,
                .ppn = @truncate(@intFromPtr(table) >> page_shift),
            };
        }

        fn address(self: Self) usize {
            return @as(usize, @intCast(self.ppn)) << page_shift;
        }
    };
}

const Lv2Entry = EntryBase(.lv2);
const Lv1Entry = EntryBase(.lv1);
const Lv0Entry = EntryBase(.lv0);

pub fn map4kTo(allocator: Allocator, root_paddr: usize, vaddr: usize, paddr: usize, perm: Permission) !void {
    const lv2ent = getEntry(Lv2Entry, vaddr, root_paddr);
    if (!lv2ent.valid) try allocateNewTable(Lv2Entry, lv2ent, allocator);

    const lv1ent = getEntry(Lv1Entry, vaddr, lv2ent.address());
    if (!lv1ent.valid) try allocateNewTable(Lv1Entry, lv1ent, allocator);

    const lv0ent = getEntry(Lv0Entry, vaddr, lv1ent.address());
    if (lv0ent.valid) return error.AlreadyMapped;
    const new_lv0ent = Lv0Entry.newMapPage(paddr, true, perm);
    lv0ent.* = new_lv0ent;
}

pub fn setupLv2Table(allocator: Allocator) !usize {
    const page = try allocator.alignedAlloc(Lv2Entry, .fromByteUnits(page_size), num_table_entries);
    @memset(page, std.mem.zeroes(Lv2Entry));
    return @intFromPtr(page.ptr);
}

pub fn enablePaging(root_paddr: usize) void {
    const satp = am.Satp{
        .mode = 8, // Sv39
        .ppn = @truncate(root_paddr >> page_shift),
    };
    satp.load();
    am.clearTLBCache();
}

fn getEntry(T: type, vaddr: usize, paddr: usize) *T {
    const table = getTable(T, paddr);
    const shift = switch (T) {
        Lv2Entry => 30,
        Lv1Entry => 21,
        Lv0Entry => 12,
        else => @compileError("unknown type"),
    };
    return &table[(vaddr >> shift) & 0x1FF];
}

fn getTable(T: type, paddr: usize) []T {
    const ptr: [*]T = @ptrFromInt(paddr & ~page_mask);
    return ptr[0..num_table_entries];
}

fn allocateNewTable(T: type, entry: *T, allocator: Allocator) !void {
    const page = try allocator.alignedAlloc(T.LowerType, .fromByteUnits(page_size), num_table_entries);
    @memset(page, std.mem.zeroes(T.LowerType));
    entry.* = T.newMapTable(page.ptr, true);
}
