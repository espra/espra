// Public Domain (-) 2026-present, The Espra Core Authors.
// See the Espra Core UNLICENSE file for details.

const builtin = @import("builtin");
const std = @import("std");

const min_zig_version = "0.16.0-dev.2915+065c6e794";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;
    const is_darwin = os == .macos or os == .ios;

    // Check Zig version
    const min_zig_semver = std.SemanticVersion.parse(min_zig_version) catch {
        std.log.err("Failed to parse the minimum Zig version", .{});
        std.process.exit(1);
    };

    if (builtin.zig_version.order(min_zig_semver) == .lt) {
        std.log.err("Zig {s} is required. Please run `zigup fetch {s} && zigup default {s}`", .{ min_zig_version, min_zig_version, min_zig_version });
        std.process.exit(1);
    }

    // Check for build dependencies
    const required_tools = .{ "cargo", "make", "rustc", "python3" };
    inline for (required_tools) |tool| {
        _ = b.findProgram(&.{tool}, &.{}) catch {
            std.log.err("Failed to find '{s}' in PATH. Please install it", .{tool});
            std.process.exit(1);
        };
    }

    // Run make to create generated files
    const make = b.addSystemCommand(&.{ "make", "-s", "generate" });

    // Create modules
    const appframe_mod = b.addModule("appframe", .{
        .root_source_file = b.path("lib/appframe/appframe.zig"),
        .target = target,
        .optimize = optimize,
    });

    const sys_mod = b.addModule("sys", .{
        .root_source_file = b.path("lib/sys/sys.zig"),
        .target = target,
        .optimize = optimize,
    });

    const time_mod = b.addModule("time", .{
        .root_source_file = b.path("lib/time/time.zig"),
        .target = target,
        .optimize = optimize,
    });

    const xxh3_mod = b.addModule("xxh3", .{
        .root_source_file = b.path("lib/xxh3/xxh3.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Create executables
    const scaffold_exe = b.addExecutable(.{
        .name = "scaffold",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/scaffold/scaffold.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // NOTE(tav): For some reason, Zig's build system doesn't seem to allow
    // dependencies to be added directly to the modules, so we have to add it to
    // the end executables instead?
    scaffold_exe.step.dependOn(&make.step);

    // Link dependencies
    if (is_darwin) {
        appframe_mod.linkSystemLibrary("objc", .{});
        appframe_mod.linkFramework("Foundation", .{});
        sys_mod.linkSystemLibrary("objc", .{});
        sys_mod.linkFramework("Foundation", .{});
        if (os == .macos) {
            appframe_mod.linkFramework("AppKit", .{});
        } else {
            appframe_mod.linkFramework("UIKit", .{});
        }
    }

    xxh3_mod.addIncludePath(b.path("dep/xxhash"));
    xxh3_mod.addCSourceFile(.{
        .file = b.path("dep/xxhash/xxhash.c"),
        .flags = &.{
            "-DXXH_CPU_LITTLE_ENDIAN=1",
        },
    });

    // Add module imports
    time_mod.addImport("sys", sys_mod);
    time_mod.addImport("xxh3", xxh3_mod);

    // Add executable imports
    scaffold_exe.root_module.addImport("sys", sys_mod);
    scaffold_exe.root_module.addImport("time", time_mod);

    // Install executables
    b.installArtifact(scaffold_exe);

    // Add tests
    const test_step = b.step("test", "Run tests");
    const test_files = .{
        .{ "time", time_mod },
        .{ "xxh3", xxh3_mod },
    };
    inline for (test_files) |entry| {
        const t = b.addTest(.{ .root_module = entry[1] });
        t.step.dependOn(&make.step);
        t.filters = b.args orelse &.{};
        const run = b.addRunArtifact(t);
        test_step.dependOn(&run.step);
        const mod_test_step = b.step("test-" ++ entry[0], "Run " ++ entry[0] ++ " tests");
        mod_test_step.dependOn(&run.step);
    }

    // Define custom steps
    const run_cmd = b.addRunArtifact(scaffold_exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run scaffold");
    run_step.dependOn(&run_cmd.step);
}
