// Public Domain (-) 2026-present, The Espra Core Authors.
// See the Espra Core UNLICENSE file for details.

const builtin = @import("builtin");
const std = @import("std");

const min_zig_version = "0.16.0-dev.2915+065c6e794";

const ZigModule = struct {
    name: []const u8,
    module: *std.Build.Module,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;
    const is_android = os == .linux and builtin.abi == .android;
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

    // Build environment variables
    const zig_path = b.graph.zig_exe;
    const zig_triple = target.result.zigTriple(b.allocator) catch @panic("OOM");
    const rust_triple = zig_to_rust_triple(target.result);

    const ar = std.fmt.allocPrint(b.allocator, "{s} ar", .{zig_path}) catch @panic("OOM");
    const cc = std.fmt.allocPrint(b.allocator, "{s} -target {s}", .{ zig_path, zig_triple }) catch @panic("OOM");

    // Run make to create generated files
    const make = b.addSystemCommand(&.{ "make", "-s", "generate" });
    make.setEnvironmentVariable("AR", ar);
    make.setEnvironmentVariable("CARGO_BUILD_TARGET", rust_triple);
    make.setEnvironmentVariable("CC", cc);

    // Create modules
    var zig_modules: std.ArrayList(ZigModule) = .empty;
    const appframe_mod = add_module(b, "appframe", target, optimize, &zig_modules);
    const bench_mod = add_module(b, "bench", target, optimize, &zig_modules);
    const cli_mod = add_module(b, "cli", target, optimize, &zig_modules);
    const gfx_mod = add_module(b, "gfx", target, optimize, &zig_modules);
    const ident_mod = add_module(b, "ident", target, optimize, &zig_modules);
    const sys_mod = add_module(b, "sys", target, optimize, &zig_modules);
    const time_mod = add_module(b, "time", target, optimize, &zig_modules);
    const wgpu_mod = add_module(b, "wgpu", target, optimize, &zig_modules);
    const wuffs_mod = add_module(b, "wuffs", target, optimize, &zig_modules);
    const xxh3_mod = add_module(b, "xxh3", target, optimize, &zig_modules);

    const wgpu_native_c = b.addTranslateC(.{
        .root_source_file = b.path("dep/wgpu-native/ffi/wgpu.h"),
        .target = target,
        .optimize = optimize,
    });

    wgpu_native_c.addIncludePath(b.path("dep/wgpu-native/ffi/webgpu-headers"));
    wgpu_native_c.step.dependOn(&make.step);

    const wgpu_native_mod = wgpu_native_c.createModule();

    wuffs_mod.addCSourceFile(.{
        .file = b.path("dep/wuffs/release/c/wuffs-unsupported-snapshot.c"),
        .flags = &.{
            "-DWUFFS_IMPLEMENTATION",
            "-DWUFFS_CONFIG__MODULES",
            "-DWUFFS_CONFIG__MODULE__ADLER32",
            "-DWUFFS_CONFIG__MODULE__BASE",
            "-DWUFFS_CONFIG__MODULE__BMP",
            "-DWUFFS_CONFIG__MODULE__BZIP2",
            "-DWUFFS_CONFIG__MODULE__CRC32",
            "-DWUFFS_CONFIG__MODULE__CRC64",
            "-DWUFFS_CONFIG__MODULE__DEFLATE",
            "-DWUFFS_CONFIG__MODULE__GIF",
            "-DWUFFS_CONFIG__MODULE__GZIP",
            "-DWUFFS_CONFIG__MODULE__JPEG",
            "-DWUFFS_CONFIG__MODULE__LZIP",
            "-DWUFFS_CONFIG__MODULE__LZMA",
            "-DWUFFS_CONFIG__MODULE__LZW",
            "-DWUFFS_CONFIG__MODULE__PNG",
            "-DWUFFS_CONFIG__MODULE__QOI",
            "-DWUFFS_CONFIG__MODULE__SHA256",
            "-DWUFFS_CONFIG__MODULE__THUMBHASH",
            "-DWUFFS_CONFIG__MODULE__VP8",
            "-DWUFFS_CONFIG__MODULE__WEBP",
            "-DWUFFS_CONFIG__MODULE__XZ",
            "-DWUFFS_CONFIG__MODULE__ZLIB",
        },
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
        wgpu_native_mod.linkFramework("Foundation", .{});
        wgpu_native_mod.linkFramework("Metal", .{});
        wgpu_native_mod.linkFramework("QuartzCore", .{});
        if (os == .macos) {
            appframe_mod.linkFramework("AppKit", .{});
        } else {
            appframe_mod.linkFramework("UIKit", .{});
        }
    } else if (os == .linux) {
        wgpu_native_mod.linkSystemLibrary("dl", .{});
        wgpu_native_mod.linkSystemLibrary("m", .{});
        if (is_android) {
            wgpu_native_mod.linkSystemLibrary("android", .{});
        }
    } else if (os == .windows) {
        wgpu_native_mod.linkSystemLibrary("Propsys", .{});
        wgpu_native_mod.linkSystemLibrary("RuntimeObject", .{});
        wgpu_native_mod.linkSystemLibrary("bcrypt", .{});
        wgpu_native_mod.linkSystemLibrary("d3dcompiler", .{});
        wgpu_native_mod.linkSystemLibrary("ntdll", .{});
        wgpu_native_mod.linkSystemLibrary("opengl32", .{});
        wgpu_native_mod.linkSystemLibrary("userenv", .{});
        wgpu_native_mod.linkSystemLibrary("ws2_32", .{});
    }

    xxh3_mod.addIncludePath(b.path("dep/xxhash"));
    xxh3_mod.addCSourceFile(.{
        .file = b.path("dep/xxhash/xxhash.c"),
        .flags = &.{
            "-DXXH_CPU_LITTLE_ENDIAN=1",
        },
    });

    wgpu_native_mod.addObjectFile(b.path("dep/wgpu-native/target/release/libwgpu_native.a"));

    // Add module imports
    appframe_mod.addImport("wgpu", wgpu_mod);
    gfx_mod.addImport("wuffs", wuffs_mod);
    time_mod.addImport("sys", sys_mod);
    time_mod.addImport("xxh3", xxh3_mod);
    wgpu_mod.addImport("wgpu-native", wgpu_native_mod);

    // Add executable imports
    scaffold_exe.root_module.addImport("appframe", appframe_mod);
    scaffold_exe.root_module.addImport("bench", bench_mod);
    scaffold_exe.root_module.addImport("cli", cli_mod);
    scaffold_exe.root_module.addImport("gfx", gfx_mod);
    scaffold_exe.root_module.addImport("ident", ident_mod);
    scaffold_exe.root_module.addImport("sys", sys_mod);
    scaffold_exe.root_module.addImport("time", time_mod);

    // Install executables
    b.installArtifact(scaffold_exe);

    // Add tests
    const test_step = b.step("test", "Run tests");
    for (zig_modules.items) |zig_module| {
        const t = b.addTest(.{ .root_module = zig_module.module });
        t.step.dependOn(&make.step);
        t.filters = b.args orelse &.{};
        const run = b.addRunArtifact(t);
        test_step.dependOn(&run.step);
        const mod_test_step = b.step(b.fmt("test-{s}", .{zig_module.name}), b.fmt("Run {s} tests", .{zig_module.name}));
        mod_test_step.dependOn(&run.step);
    }

    // Define custom steps
    const run_cmd = b.addRunArtifact(scaffold_exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run scaffold");
    run_step.dependOn(&run_cmd.step);
}

fn add_module(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zig_modules: *std.ArrayList(ZigModule),
) *std.Build.Module {
    const mod = b.addModule(name, .{
        .root_source_file = b.path(b.fmt("lib/{s}/{s}.zig", .{ name, name })),
        .target = target,
        .optimize = optimize,
    });
    zig_modules.append(b.allocator, .{ .name = name, .module = mod }) catch @panic("OOM");
    return mod;
}

fn zig_to_rust_triple(target: std.Target) []const u8 {
    switch (target.os.tag) {
        .ios => {
            if (target.cpu.arch == .aarch64) {
                switch (target.abi) {
                    .none => {
                        return "aarch64-apple-ios";
                    },
                    .simulator => {
                        return "aarch64-apple-ios-sim";
                    },
                    else => {},
                }
            }
        },
        .linux => {
            switch (target.cpu.arch) {
                .aarch64 => {
                    switch (target.abi) {
                        .gnu => {
                            return "aarch64-unknown-linux-gnu";
                        },
                        .musl => {
                            return "aarch64-unknown-linux-musl";
                        },
                        else => {},
                    }
                },
                .x86_64 => {
                    switch (target.abi) {
                        .gnu => {
                            return "x86_64-unknown-linux-gnu";
                        },
                        .musl => {
                            return "x86_64-unknown-linux-musl";
                        },
                        else => {},
                    }
                },
                else => {},
            }
        },
        .macos => {
            if (target.cpu.arch == .aarch64) {
                return "aarch64-apple-darwin";
            }
        },
        .windows => {
            if (target.cpu.arch == .x86_64) {
                switch (target.abi) {
                    .gnu => {
                        return "x86_64-pc-windows-gnu";
                    },
                    .msvc => {
                        return "x86_64-pc-windows-msvc";
                    },
                    else => {},
                }
            }
        },
        else => {},
    }
    @panic("Unsupported OS, architecture, and ABI combination");
}
