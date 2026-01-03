const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv64,
        .os_tag = .freestanding,
        .cpu_model = .baseline,
    });
    const optimize: std.builtin.OptimizeMode = .ReleaseFast;

    const out_dir_name = "img";

    const mod = b.addModule("mame", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .code_model = .medany,
    });

    const mame = b.addExecutable(.{
        .name = "mame",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/boot.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mame", .module = mod },
            },
            .code_model = .medany,
        }),
        .linkage = .static,
    });
    mame.linker_script = b.path("kernel.ld");
    mame.entry = .{ .symbol_name = "boot" };

    b.installArtifact(mame);

    const install_mame = b.addInstallFile(
        mame.getEmittedBin(),
        b.fmt("{s}/{s}", .{
            out_dir_name,
            mame.name,
        }),
    );
    install_mame.step.dependOn(&mame.step);
    b.getInstallStep().dependOn(&install_mame.step);

    const run_step = b.step("run", "Run the app");

    const qemu_args = [_][]const u8{
        "qemu-system-riscv64",
        "-machine",
        "virt",
        "-bios",
        "default",
        "-nographic",
        "-serial",
        "mon:stdio",
        "--no-reboot",
        "-kernel",
        b.fmt("{s}/{s}", .{ b.install_path, install_mame.dest_rel_path }),
        "-s",
    };
    const run_cmd = b.addSystemCommand(&qemu_args);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = mame.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const check_step = b.step("check", "Check compilation");
    check_step.dependOn(&mame.step);
}
