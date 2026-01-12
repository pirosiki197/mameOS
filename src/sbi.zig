const mame = @import("mame");
const va2pa = mame.page.va2pa;

pub const SbiError = error{
    failed,
    not_supported,
    invalid_param,
    denied,
    invalid_address,
    already_available,
    already_started,
    already_stopped,
    no_shmem,
};

const ecall = struct {
    const EID = enum(usize) {
        dbcn = 0x4442434e,
        time = 0x54494d45,
        _,
    };

    inline fn convertError(err_code: i32, value: i32) SbiError!i32 {
        return switch (err_code) {
            0 => value,
            -1 => SbiError.failed,
            -2 => SbiError.not_supported,
            -3 => SbiError.invalid_param,
            -4 => SbiError.denied,
            -5 => SbiError.invalid_address,
            -6 => SbiError.already_available,
            -7 => SbiError.already_started,
            -8 => SbiError.already_stopped,
            -9 => SbiError.no_shmem,
            else => unreachable,
        };
    }

    inline fn oneArg64NoReturnNoError(eid: EID, fid: u32, arg0: u64) void {
        asm volatile ("ecall"
            :
            : [eid] "{a7}" (@intFromEnum(eid)),
              [fid] "{a6}" (fid),
              [arg0] "{a0}" (arg0),
        );
    }

    inline fn threeArgs(eid: EID, fid: usize, arg0: u32, arg1: u32, arg2: u32) SbiError!i32 {
        var err: i32 = undefined;
        var value: i32 = undefined;
        asm volatile ("ecall"
            : [err] "={a0}" (err),
              [value] "={a1}" (value),
            : [eid] "{a7}" (@intFromEnum(eid)),
              [fid] "{a6}" (fid),
              [arg0] "{a0}" (@as(usize, arg0)),
              [arg1] "{a1}" (@as(usize, arg1)),
              [arg2] "{a2}" (@as(usize, arg2)),
        );
        return convertError(err, value);
    }
};

pub const console = struct {
    const FID = enum(usize) {
        write = 0,
        read = 1,
        write_byte = 2,
    };

    pub fn write(b: []const u8) SbiError!usize {
        const paddr = va2pa(@intFromPtr(b.ptr));
        const ret = try ecall.threeArgs(
            .dbcn,
            @intFromEnum(FID.write),
            @intCast(b.len),
            @intCast(paddr & 0xffff_ffff),
            @intCast(paddr >> 32),
        );
        return @intCast(ret);
    }
};

pub const timer = struct {
    const FID = enum(usize) {
        set = 0,
    };

    pub fn set(time_val: u64) void {
        ecall.oneArg64NoReturnNoError(.time, @intFromEnum(FID.set), time_val);
    }
};
