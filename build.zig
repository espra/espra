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

    // Add module imports
    time_mod.addImport("sys", sys_mod);

    // Add executable imports
    scaffold_exe.root_module.addImport("sys", sys_mod);
    scaffold_exe.root_module.addImport("time", time_mod);

    // Install executables
    b.installArtifact(scaffold_exe);

    // Add tests
    const test_step = b.step("test", "Run tests");
    const test_files = .{
        .{ "lib/time/time.zig", .{.{ "sys", sys_mod }} },
    };

    inline for (test_files) |entry| {
        const m = b.createModule(.{
            .root_source_file = b.path(entry[0]),
            .target = target,
            .optimize = optimize,
        });
        inline for (entry[1]) |imp| {
            m.addImport(imp[0], imp[1]);
        }
        const t = b.addTest(.{ .root_module = m });
        t.step.dependOn(&make.step);
        t.filters = b.args orelse &.{};
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Define custom steps
    const run_cmd = b.addRunArtifact(scaffold_exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run scaffold");
    run_step.dependOn(&run_cmd.step);
}
