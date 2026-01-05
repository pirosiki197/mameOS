const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv64,
        .os_tag = .freestanding,
        .cpu_model = .baseline,
    });
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse .ReleaseFast;

    const mame_mod = createMameModule(b, target, optimize);
    const kernel = createKernel(b, target, optimize, mame_mod);
    const install_kernel = b.addInstallArtifact(
        kernel,
        .{ .dest_dir = .{ .override = .{ .custom = "img" } } },
    );
    b.getInstallStep().dependOn(&install_kernel.step);

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

fn createMameModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const log_level = b.option(std.log.Level, "log_level", "debug, info, warn, error") orelse .info;

    const options = b.addOptions();
    options.addOption(std.log.Level, "log_level", log_level);

    const mod = b.addModule("mame", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .medany,
    });
    mod.addImport("mame", mod);
    mod.addOptions("options", options);

    return mod;
}

fn createKernel(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, mod: *std.Build.Module) *std.Build.Step.Compile {
    const kernel = b.addExecutable(.{
        .name = "mame",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/boot.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "mame", .module = mod }},
            .code_model = .medany,
        }),
    });

    kernel.linker_script = b.path("kernel.ld");
    kernel.entry = .{ .symbol_name = "boot" };

    return kernel;
}

fn setupQemuStep(b: *std.Build, kernel: *std.Build.Step.Compile) *std.Build.Step {
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
