const std = @import("std");
const zlinter = @import("zlinter");

pub fn build(b: *std.Build) void {
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSmall;
    const coverage = b.option(bool, "coverage", "Collect test coverage with kcov") orelse false;
    const rpi_firmware = b.dependency("raspberrypi_firmware", .{});
    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .cpu_features_sub = std.Target.aarch64.featureSet(&.{ .fp_armv8, .neon }),
        .os_tag = .freestanding,
        .abi = .none,
    });
    const user_one = addUserProgram(b, "user_one", kernel_target, optimize, 1);
    const user_two = addUserProgram(b, "user_two", kernel_target, optimize, 2);
    const user_storage = b.addSystemCommand(&.{"python3"});
    user_storage.addFileArg(b.path("scripts/make-user-storage.py"));
    user_storage.addFileArg(user_one.getEmittedBin());
    user_storage.addFileArg(user_two.getEmittedBin());
    const initramfs = user_storage.addOutputFileArg("initramfs.cpio");
    const user_disk = user_storage.addOutputFileArg("users-fat16.img");
    const generated_users = b.addWriteFiles();
    _ = generated_users.addCopyFile(user_one.getEmittedBin(), "user_one.elf");
    _ = generated_users.addCopyFile(user_two.getEmittedBin(), "user_two.elf");
    _ = generated_users.addCopyFile(initramfs, "initramfs.cpio");
    const embedded_users = b.createModule(.{
        .root_source_file = generated_users.add("embedded_users.zig",
            \\pub const one align(8) = @embedFile("user_one.elf").*;
            \\pub const two align(8) = @embedFile("user_two.elf").*;
            \\pub const initramfs align(8) = @embedFile("initramfs.cpio").*;
        ),
    });

    const kernel = addKernel(
        b,
        "thekorn_os",
        kernel_target,
        optimize,
        b.path("src/platform/qemu_virt/uart.zig"),
    );
    kernel.setLinkerScript(b.path("src/platform/qemu_virt/linker.ld"));
    kernel.root_module.addImport("embedded_users", embedded_users);

    const rpi_kernel = addKernel(
        b,
        "thekorn_os_rpi4",
        kernel_target,
        optimize,
        b.path("src/platform/rpi4/uart.zig"),
    );
    rpi_kernel.setLinkerScript(b.path("src/arch/aarch64/linker.ld"));
    rpi_kernel.root_module.addImport("embedded_users", embedded_users);

    const install_elf = b.addInstallArtifact(kernel, .{});
    const image = rpi_kernel.addObjCopy(.{
        .basename = "kernel8.img",
        .format = .binary,
    });
    const install_image = b.addInstallFile(image.getOutput(), "kernel8.img");
    const install_user_disk = b.addInstallFile(user_disk, "users-fat16.img");
    const rpi_disk = b.addSystemCommand(&.{"bash"});
    rpi_disk.addFileArg(b.path("scripts/make-rpi4-image.sh"));
    rpi_disk.addFileArg(image.getOutput());
    rpi_disk.addFileArg(b.path("scripts/rpi4-config.txt"));
    rpi_disk.addFileArg(rpi_firmware.path("boot/start4.elf"));
    rpi_disk.addFileArg(rpi_firmware.path("boot/fixup4.dat"));
    rpi_disk.addFileArg(rpi_firmware.path("boot/LICENCE.broadcom"));
    const rpi_dtb = b.addSystemCommand(&.{"python3"});
    rpi_dtb.addFileArg(b.path("scripts/fetch-rpi4-dtb.py"));
    const rpi_dtb_output = rpi_dtb.addOutputFileArg("bcm2711-rpi-4-b.dtb");
    rpi_disk.addFileArg(rpi_dtb_output);
    rpi_disk.addArg("1.20260521");
    const rpi_disk_output = rpi_disk.addOutputFileArg("thekorn-os-rpi4.img");
    const install_rpi_disk = b.addInstallFile(rpi_disk_output, "thekorn-os-rpi4.img");
    b.getInstallStep().dependOn(&install_elf.step);
    b.getInstallStep().dependOn(&install_image.step);
    b.getInstallStep().dependOn(&install_user_disk.step);
    b.getInstallStep().dependOn(&install_rpi_disk.step);

    const qemu_image = kernel.addObjCopy(.{ .format = .binary });
    addQemuStep(b, "run-virt", "Run the kernel on QEMU virt", qemu_image.getOutput(), user_disk, false, false);
    addQemuStep(b, "run-virt-gui", "Run the kernel with serial output in the QEMU GUI", qemu_image.getOutput(), user_disk, false, true);
    addQemuStep(b, "debug-virt", "Run QEMU virt paused with a GDB server", qemu_image.getOutput(), user_disk, true, false);

    const smoke = b.addSystemCommand(&.{"bash"});
    smoke.addFileArg(b.path("scripts/smoke-virt.sh"));
    smoke.addFileArg(qemu_image.getOutput());
    smoke.addFileArg(user_disk);
    const smoke_step = b.step("smoke-virt", "Boot QEMU and verify the serial marker");
    smoke_step.dependOn(&smoke.step);

    const native_test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.graph.host,
        .optimize = if (coverage) .Debug else optimize,
        .imports = &.{.{
            .name = "platform",
            .module = b.createModule(.{
                .root_source_file = b.path("src/platform/qemu_virt/uart.zig"),
                .target = b.graph.host,
                .optimize = if (coverage) .Debug else optimize,
            }),
        }},
    });
    native_test_module.addImport("embedded_users", embedded_users);
    const native_tests = b.addTest(.{
        .root_module = native_test_module,
        .use_llvm = if (coverage) true else null,
        .test_runner = .{
            .path = b.path("src/test_runner.zig"),
            .mode = .simple,
        },
    });
    const test_step = b.step("test", "Run tests");
    if (coverage) {
        const remove_coverage_dirs = b.addSystemCommand(&.{
            "rm",
            "-rf",
            "zig-out/kcov",
            "zig-out/coverage",
        });
        const make_coverage_dir = b.addSystemCommand(&.{ "mkdir", "-p", "zig-out/kcov" });
        make_coverage_dir.step.dependOn(&remove_coverage_dirs.step);

        const run_native_tests = b.addSystemCommand(&.{
            "kcov",
            "--clean",
            "--exclude-pattern=test_runner.zig",
            "--include-path=src",
            "zig-out/kcov/tests",
        });
        run_native_tests.addArtifactArg2(native_tests, .{});
        run_native_tests.step.dependOn(&make_coverage_dir.step);

        const merge_coverage = b.addSystemCommand(&.{
            "kcov",
            "--clean",
            "--merge",
            "zig-out/coverage",
            "zig-out/kcov/tests",
        });
        merge_coverage.step.dependOn(&run_native_tests.step);

        const print_coverage_report = b.addSystemCommand(&.{
            "jq",
            "--raw-output",
            "-s",
            ".[0] as $summary | .[1].coverage as $coverage | ($coverage | to_entries | map({ file: .key, lines: (.value | to_entries | map(select(.value == 0) | .key)) }) | map(select(.lines | length > 0))) as $uncovered | \"Coverage: \\($summary.percent_covered)% (\\($summary.covered_lines)/\\($summary.total_lines) lines)\", \"Files:\", ($summary.files[] | \"  \\(.file | sub(\"^.*/src/\"; \"src/\")): \\(.percent_covered)% (\\(.covered_lines)/\\(.total_lines) lines)\"), \"Uncovered lines:\", (if $uncovered | length == 0 then \"  none\" else $uncovered[] | \"  src/\\(.file): \\(.lines | join(\", \"))\" end)",
            "zig-out/coverage/kcov-merged/coverage.json",
            "zig-out/coverage/kcov-merged/codecov.json",
        });
        print_coverage_report.step.dependOn(&merge_coverage.step);
        test_step.dependOn(&print_coverage_report.step);
    } else {
        test_step.dependOn(&b.addRunArtifact(native_tests).step);
    }

    const lint_step = b.step("lint", "Lint source code");
    lint_step.dependOn(step: {
        var builder = zlinter.builder(b, .{});
        builder.addPaths(.{
            .include_dirs = &.{b.path("src")},
        });
        builder.addRule(.{ .builtin = .field_naming }, .{});
        builder.addRule(.{ .builtin = .declaration_naming }, .{});
        builder.addRule(.{ .builtin = .function_naming }, .{});
        builder.addRule(.{ .builtin = .file_naming }, .{});
        builder.addRule(.{ .builtin = .switch_case_ordering }, .{});
        builder.addRule(.{ .builtin = .no_unused }, .{});
        builder.addRule(.{ .builtin = .no_deprecated }, .{});
        builder.addRule(.{ .builtin = .no_orelse_unreachable }, .{});
        break :step builder.build();
    });
}

fn addUserProgram(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    process_id: u8,
) *std.Build.Step.Compile {
    const options = b.addOptions();
    options.addOption(u8, "process_id", process_id);
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/user/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
        .unwind_tables = .none,
        .pic = false,
    });
    root_module.addOptions("options", options);
    root_module.addImport("syscall", b.createModule(.{
        .root_source_file = b.path("src/kernel/syscall.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const program = b.addExecutable(.{
        .name = name,
        .root_module = root_module,
    });
    program.entry = .{ .symbol_name = "_start" };
    program.setLinkerScript(b.path("src/user/linker.ld"));
    return program;
}

fn addKernel(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform: std.Build.LazyPath,
) *std.Build.Step.Compile {
    const kernel = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
            .unwind_tables = .none,
            .pic = false,
            .imports = &.{.{
                .name = "platform",
                .module = b.createModule(.{
                    .root_source_file = platform,
                    .target = target,
                    .optimize = optimize,
                    .unwind_tables = .none,
                    .pic = false,
                }),
            }},
        }),
    });
    kernel.entry = .{ .symbol_name = "_start" };
    kernel.root_module.addAssemblyFile(b.path("src/arch/aarch64/boot.S"));
    kernel.root_module.addAssemblyFile(b.path("src/arch/aarch64/vectors.S"));
    return kernel;
}

fn addQemuStep(
    b: *std.Build,
    name: []const u8,
    description: []const u8,
    kernel: std.Build.LazyPath,
    user_disk: std.Build.LazyPath,
    debug: bool,
    gui: bool,
) void {
    const qemu = b.addSystemCommand(&.{ "bash", "-c" });
    const command = if (gui)
        \\exec qemu-system-aarch64 -machine virt -cpu cortex-a72 -smp 1 -m 128M -monitor none -serial vc:2048x1536 -global virtio-mmio.force-legacy=false -kernel "$1" -drive "file=$2,format=raw,if=none,readonly=on,id=users" -device virtio-blk-device,drive=users
    else if (debug)
        \\exec qemu-system-aarch64 -machine virt -cpu cortex-a72 -smp 1 -m 128M -nographic -global virtio-mmio.force-legacy=false -kernel "$1" -drive "file=$2,format=raw,if=none,readonly=on,id=users" -device virtio-blk-device,drive=users -S -s
    else
        \\exec qemu-system-aarch64 -machine virt -cpu cortex-a72 -smp 1 -m 128M -nographic -global virtio-mmio.force-legacy=false -kernel "$1" -drive "file=$2,format=raw,if=none,readonly=on,id=users" -device virtio-blk-device,drive=users
    ;
    qemu.addArg(command);
    qemu.addArg(name);
    qemu.addFileArg(kernel);
    qemu.addFileArg(user_disk);

    const step = b.step(name, description);
    step.dependOn(&qemu.step);
}
