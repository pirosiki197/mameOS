const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv64,
        .os_tag = .freestanding,
        .cpu_model = .baseline,
    });
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSmall;

    const mame_mod = createMameModule(b, target, optimize);
    const kernel = createKernel(b, target, optimize, mame_mod);
    const install_kernel = b.addInstallArtifact(
        kernel,
        .{ .dest_dir = .{ .override = .{ .custom = "img" } } },
    );
    b.getInstallStep().dependOn(&install_kernel.step);

    const user_step = b.step("user", "Create user binary");
    const user = createUserElf(b, target);
    user_step.dependOn(&user.step);

    const run_step = setupQemuStep(b, kernel);
    run_step.dependOn(&install_kernel.step);

    const mod_tests = b.addTest(.{
        .root_module = mame_mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = kernel.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const check_step = b.step("check", "Check compilation");
    check_step.dependOn(&kernel.step);
}

fn createMameModule(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *Build.Module {
    const log_level = b.option(std.log.Level, "log_level", "debug, info, warn, error") orelse .info;

    const options = b.addOptions();
    options.addOption(std.log.Level, "log_level", log_level);

    const mod = b.addModule("mame", .{
        .root_source_file = b.path("kernel/root.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .medany,
        .strip = false,
    });
    mod.addImport("mame", mod);
    mod.addOptions("options", options);

    return mod;
}

fn createKernel(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, mod: *Build.Module) *Build.Step.Compile {
    const kernel = b.addExecutable(.{
        .name = "mame",
        .root_module = b.createModule(.{
            .root_source_file = b.path("kernel/boot.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "mame", .module = mod }},
            .code_model = .medany,
            .strip = false,
        }),
    });

    kernel.linker_script = b.path("kernel.ld");
    kernel.entry = .{ .symbol_name = "boot" };

    return kernel;
}

fn createUserElf(b: *Build, target: Build.ResolvedTarget) *Build.Step.InstallArtifact {
    const exe = b.addExecutable(.{
        .name = "user",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/hello.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
            .strip = true,
        }),
    });
    exe.linker_script = b.path("user/user.ld");
    exe.entry = .{ .symbol_name = "start" };
    exe.out_filename = "user.elf";

    return b.addInstallArtifact(exe, .{});
}

fn setupQemuStep(b: *Build, kernel: *Build.Step.Compile) *Build.Step {
    const run_step = b.step("run", "Run mameOS in QEMU");

    const qemu = b.addSystemCommand(&.{"qemu-system-riscv64"});
    qemu.addArgs(&.{
        "-machine",   "virt",
        "-bios",      "default",
        "-nographic", "-serial",
        "mon:stdio",  "--no-reboot",
        "-s",         "-kernel",
    });
    qemu.addArtifactArg(kernel);

    run_step.dependOn(&qemu.step);

    return run_step;
}
