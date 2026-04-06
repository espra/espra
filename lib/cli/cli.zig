// Public Domain (-) 2026-present, The Espra Core Authors.
// See the Espra Core UNLICENSE file for details.

const builtin = @import("builtin");
const std = @import("std");

const Allocator = std.mem.Allocator;
const EnumField = std.builtin.Type.EnumField;

const min_terminal_width: u16 = 80;

pub fn App(comptime RootCommand: type) type {
    return AppWithGroups(RootCommand, void, void);
}

pub fn AppOptions(comptime RootCommand: type) type {
    return struct {
        complete: ?Completer(RootCommand) = null,
        description: ?[]const u8 = null,
        enable_completion_command: bool = false,
        enable_help_command: bool = false,
        env_var_prefix: ?[]const u8 = null,
        epilog: ?[]const u8 = null,
        help_heading_style: []const u8 = "\x1b[1;38;2;255;183;77m", // Plain alt: "\x1b[33;1m"
        help_heading_style_end: []const u8 = "\x1b[0m",
        print_deprecations: ?*const fn (Allocator, *std.Io.Writer, app_name: []const u8, []const Deprecation) anyerror!void = null,
        print_error: ?*const fn (Allocator, *std.Io.Writer, app_name: []const u8, ErrorResult) anyerror!void = null,
        print_help: ?*const fn (Allocator, *std.Io.Writer, HelpContext(RootCommand)) anyerror!void = null,
        max_args: ?usize = null,
        min_args: ?usize = null,
        name: []const u8,
        preserve_unmatched_short_options: bool = false,
        prolog: ?[]const u8 = null,
        show_defaults: ?bool = null,
        subcommands_only: bool = false,
        summary: ?[]const u8 = null,
        usage: ?Usage = null,
        version: ?[]const u8 = null,
    };
}

pub fn AppWithGroups(comptime RootCommand: type, comptime SubcommandGroup: type, comptime OptionGroup: type) type {
    if (SubcommandGroup != void and @typeInfo(SubcommandGroup) != .@"enum") {
        @compileError("SubcommandGroup must be an enum type");
    }
    if (OptionGroup != void and @typeInfo(OptionGroup) != .@"enum") {
        @compileError("OptionGroup must be an enum type");
    }
    const subcommands_count = find_subcommands(RootCommand, "");
    const options_count = find_options(RootCommand, "");

    const ResolvedCommand = struct {
        aliases: []const Subcommand(RootCommand),
        complete: ?Completer(RootCommand),
        deprecated: ?[]const u8,
        description: ?[]const u8,
        epilog: ?[]const u8,
        group: ?SubcommandGroup,
        hidden: bool,
        max_args: ?usize,
        min_args: ?usize,
        name: ?[]const u8,
        preserve_unmatched_short_options: bool,
        prolog: ?[]const u8,
        struct_path: []const u8,
        subcommands_only: bool,
        summary: ?[]const u8,
        usage: ?Usage,
    };

    return struct {
        app_options: AppOptions(RootCommand),
        option_names: [options_count][]const u8,
        options: [options_count]?OptionInfo(RootCommand, OptionGroup),
        require_explicit: bool,
        subcommand_names: [subcommands_count][]const u8,
        subcommands: [subcommands_count]?SubcommandInfo(RootCommand, SubcommandGroup),

        const Self = @This();

        pub fn init(options: AppOptions(RootCommand)) Self {
            comptime var option_idx: usize = 0;
            comptime var option_names: [options_count][]const u8 = undefined;
            comptime var subcommand_idx: usize = 0;
            comptime var subcommand_names: [subcommands_count][]const u8 = undefined;
            comptime collect_field_names(RootCommand, unqualified_type_name(RootCommand), &option_idx, &option_names, &subcommand_idx, &subcommand_names);

            return .{
                .app_options = options,
                .option_names = option_names,
                .options = .{null} ** options_count,
                .require_explicit = false,
                .subcommand_names = subcommand_names,
                .subcommands = .{null} ** subcommands_count,
            };
        }

        pub fn option(self: *Self, opt: Option(RootCommand), info: OptionInfo(RootCommand, OptionGroup)) void {
            self.options[@intFromEnum(opt) & 0xFFFFFFFF] = info;
        }

        pub fn parse(self: *Self, proc: std.process.Init) SuccessResult(RootCommand) {
            const arena = proc.gpa.create(std.heap.ArenaAllocator) catch oom(self.app_options.name);
            arena.* = std.heap.ArenaAllocator.init(proc.gpa);
            const allocator = arena.allocator();
            const raw_args = proc.minimal.args.toSlice(allocator) catch oom(self.app_options.name);
            const args = if (raw_args.len > 0) raw_args[1..] else raw_args;
            const result = self.parse_raw(arena, args, proc.minimal.environ);
            switch (result) {
                .ok => |r| {
                    if (r.deprecations) |deprecations| {
                        self.print_deprecations(allocator, proc.io, self.app_options.name, deprecations);
                    }
                    return r;
                },
                .err => |e| {
                    self.print_error(allocator, proc.io, self.app_options.name, e);
                    std.process.exit(1);
                },
            }
        }

        pub fn parse_raw(self: *Self, arena: *std.heap.ArenaAllocator, args: []const []const u8, env: std.process.Environ) ParseResult(RootCommand) {
            const allocator = arena.allocator();
            const autocomplete = env.getAlloc(allocator, "CLI_AUTOCOMPLETE") catch |err| switch (err) {
                error.EnvironmentVariableMissing => null,
                error.InvalidWtf8 => exit_error(self.app_options.name, "invalid WTF-8 environment variable"),
                error.OutOfMemory => oom(self.app_options.name),
            };
            if (autocomplete) |shell| {
                self.run_completion(shell);
                std.process.exit(0);
            }
            if (self.require_explicit) {
                if (self.check_explicit_definitions()) |err| {
                    return .{
                        .err = .{ .missing_definition = err },
                    };
                }
            }
            if (self.validate_definitions(allocator)) |err| {
                return .{
                    .err = .{ .validation = err },
                };
            }
            _ = args;
            return .{
                .ok = .{
                    .arena = arena,
                    .args = &.{},
                    .deprecations = null,
                    .invoked_command = .Default,
                    .root = undefined,
                    .unmatched_short_options = null,
                },
            };
        }

        pub fn print_help(self: *Self, allocator: Allocator, io: std.Io, cmd: InvokedCommand(RootCommand)) !void {
            var buf: [64]u8 = undefined;
            var stdout = std.Io.File.stdout().writer(io, &buf);
            const w = &stdout.interface;
            try self.print_help_to(allocator, w, cmd);
        }

        pub fn print_help_to(self: *Self, allocator: Allocator, w: *std.Io.Writer, cmd: InvokedCommand(RootCommand)) !void {
            const ctx = self.build_help_context(cmd);
            if (self.app_options.print_help) |print| {
                try print(allocator, w, ctx);
            } else {
                try default_print_help(allocator, w, ctx);
            }
        }

        pub fn require_explicit_definitions(self: *Self) void {
            self.require_explicit = true;
        }

        pub fn subcommand(self: *Self, cmd: Subcommand(RootCommand), info: SubcommandInfo(RootCommand, SubcommandGroup)) void {
            self.subcommands[(@intFromEnum(cmd) & 0xFFFF) - 1] = info;
        }

        fn build_help_context(self: *Self, cmd: InvokedCommand(RootCommand)) HelpContext(RootCommand) {
            _ = cmd;
            return .{
                .app = self.app_options,
                .command = .{
                    .description = null,
                    .epilog = null,
                    .prolog = null,
                    .summary = null,
                    .usage = null,
                },
                .command_path = "",
                .max_option_width = 0,
                .max_subcommand_width = 0,
                .option_groups = &.{},
                .subcommand_groups = &.{},
                .terminal_width = 0,
            };
        }

        fn check_explicit_definitions(self: *Self) ?MissingDefinitionError {
            for (0..subcommands_count) |i| {
                if (self.subcommands[i] == null) {
                    return .{ .subcommand = self.subcommand_names[i] };
                }
            }
            for (0..options_count) |i| {
                if (self.options[i] == null) {
                    return .{ .option = self.option_names[i] };
                }
            }
            return null;
        }

        fn print_deprecations(self: *Self, allocator: Allocator, io: std.Io, app_name: []const u8, deprecations: []const Deprecation) void {
            var buf: [64]u8 = undefined;
            var stderr = std.Io.File.stderr().writer(io, &buf);
            const w = &stderr.interface;
            if (self.app_options.print_deprecations) |print| {
                print(allocator, w, app_name, deprecations) catch {};
                return;
            }
            default_print_deprecations(allocator, w, app_name, deprecations) catch {};
        }

        fn print_error(self: *Self, allocator: Allocator, io: std.Io, app_name: []const u8, err: ErrorResult) void {
            var buf: [64]u8 = undefined;
            var stderr = std.Io.File.stderr().writer(io, &buf);
            const w = &stderr.interface;
            if (self.app_options.print_error) |print| {
                print(allocator, w, app_name, err) catch {};
                return;
            }
            default_print_error(allocator, w, app_name, err) catch {};
        }

        fn run_completion(self: *Self, shell: []const u8) void {
            _ = self;
            _ = shell;
        }

        fn validate_definitions(self: *Self, allocator: Allocator) ?ValidationError {
            var foo: std.AutoHashMapUnmanaged(u8, void) = .empty;
            for (self.subcommands, 0..) |s, i| if (s) |info| {
                if (info.name) |name| {
                    if (name.len == 0) {
                        return .{
                            .subcommand = .{
                                .message = "`name` is an empty string",
                                .subcommand_name = self.subcommand_names[i],
                            },
                        };
                    }
                }
                if (info.subcommands_only) {
                    if (info.min_args) |min_args| {
                        if (min_args > 0) {
                            return .{
                                .subcommand = .{
                                    .message = "cannot set both `subcommands_only` and `min_args`",
                                    .subcommand_name = self.subcommand_names[i],
                                },
                            };
                        }
                    }
                    if (info.max_args) |max_args| {
                        if (max_args > 0) {
                            return .{
                                .subcommand = .{
                                    .message = "cannot set both `subcommands_only` and `max_args`",
                                    .subcommand_name = self.subcommand_names[i],
                                },
                            };
                        }
                    }
                }
            };
            for (self.options, 0..) |o, i| if (o) |info| {
                if (info.long) |long| {
                    if (long.len == 0) {
                        return .{
                            .option = .{
                                .message = "`long` is an empty string",
                                .option_name = self.option_names[i],
                            },
                        };
                    }
                    if (long.len == 1) {
                        return .{
                            .option = .{
                                .message = "`long` is a single character",
                                .option_name = self.option_names[i],
                            },
                        };
                    }
                    if (long[0] == '-') {
                        return .{
                            .option = .{
                                .message = "`long` starts with a hyphen",
                                .option_name = self.option_names[i],
                            },
                        };
                    }
                    if (is_invalid_long_flag(long)) |char| {
                        return .{
                            .option = .{
                                .message = std.fmt.allocPrint(allocator, "`long` contains an invalid character: \"{c}\" (0x{x})", .{ char, char }) catch oom(self.app_options.name),
                                .option_name = self.option_names[i],
                            },
                        };
                    }
                }
                if (info.short) |short| {
                    if (is_invalid_short_flag(short)) {
                        return .{
                            .option = .{
                                .message = std.fmt.allocPrint(allocator, "`short` value is invalid: \"{c}\" (0x{x})", .{ short, short }) catch oom(self.app_options.name),
                                .option_name = self.option_names[i],
                            },
                        };
                    }
                }
            };

            // depends_on value {}
            // mutually_exclusive_with value {}
            // field {} needs to either be required or have a default value

            // Subcommands:
            // name conflicts with [ name inferred | name set ]
            return null;
        }

        fn default_print_deprecations(allocator: Allocator, w: *std.Io.Writer, app_name: []const u8, deprecations: []const Deprecation) !void {
            _ = allocator;
            for (deprecations) |deprecation| switch (deprecation) {
                .option => |opt| {
                    try w.print("\x1b[31mWARNING: {s}: deprecated option \"{s}\" for \"{s}\", {s}\x1b[0m\n", .{ app_name, opt.option_name, opt.command_path, opt.message });
                },
                .subcommand => |cmd| {
                    try w.print("\x1b[31mWARNING: {s}: deprecated subcommand \"{s}\", {s}\x1b[0m\n", .{ app_name, cmd.command_path, cmd.message });
                },
            };
            try w.flush();
        }

        fn default_print_error(allocator: Allocator, w: *std.Io.Writer, app_name: []const u8, err: ErrorResult) !void {
            _ = allocator;
            try w.print("\x1b[31mERROR: {s}: ", .{app_name});
            switch (err) {
                .command => |cmd_err| {
                    try w.print("command error: {s} ", .{cmd_err.command_path});
                },
                .missing_definition => |definition| switch (definition) {
                    .option => |option_name| {
                        try w.print("missing explicit definition for option: {s} ", .{option_name});
                    },
                    .subcommand => |subcommand_name| {
                        try w.print("missing explicit definition for subcommand: {s} ", .{subcommand_name});
                    },
                },
                .option => |opt_err| {
                    try w.print("option error: {s} ", .{opt_err.option_name});
                },
                .validation => |validation| switch (validation) {
                    .option => |v| {
                        try w.print("invalid option definition for {s}: {s} ", .{ v.option_name, v.message });
                    },
                    .subcommand => |v| {
                        try w.print("invalid subcommand definition for {s}: {s} ", .{ v.subcommand_name, v.message });
                    },
                },
            }
            try w.print("\x1b[0m\n", .{});
            try w.flush();
        }

        fn default_print_help(allocator: Allocator, w: *std.Io.Writer, ctx: HelpContext(RootCommand)) !void {
            _ = allocator;
            const heading = ctx.app.help_heading_style;
            const heading_end = ctx.app.help_heading_style_end;
            try w.print("{s}USAGE{s}\n", .{ heading, heading_end });
            try w.flush();
        }
    };
}

pub const CommandError = struct {
    command_path: []const u8,
    kind: Kind,

    pub const Kind = union(enum) {
        too_few_args: struct { min_args: usize, usage: []const u8 },
        too_many_args: struct { max_args: usize, usage: []const u8 },
        unknown_option: struct { option_name: []const u8 },
    };
};

pub const CommandHelpEntry = struct {
    description: ?[]const u8 = null,
    epilog: ?[]const u8 = null,
    prolog: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    usage: ?[]const u8 = null,
};

pub const DeprecatedOption = struct {
    command_path: []const u8,
    message: []const u8,
    option_name: []const u8,
};

pub const DeprecatedSubcommand = struct {
    command_path: []const u8,
    message: []const u8,
};

pub const Deprecation = union(enum) {
    option: DeprecatedOption,
    subcommand: DeprecatedSubcommand,
};

pub fn Completer(comptime RootCommand: type) type {
    return *const fn (
        allocator: Allocator,
        root: *const RootCommand,
        invoked_command: InvokedCommand(RootCommand),
        args: []const u8,
    ) anyerror![]const Completion;
}

pub const Completion = struct {
    description: ?[]const u8 = null,
    value: []const u8,
};

pub fn DecodeResult(comptime T: type) type {
    return union(enum) {
        err: []const u8,
        ok: T,
    };
}

pub const ErrorResult = union(enum) {
    command: CommandError,
    missing_definition: MissingDefinitionError,
    option: OptionError,
    validation: ValidationError,
};

pub const GroupKind = union(enum) {
    default,
    global,
    inherited,
    named: []const u8,
};

pub fn Group(comptime T: type) type {
    return struct {
        items: []const T,
        kind: GroupKind,
    };
}

pub fn HelpContext(comptime RootCommand: type) type {
    return struct {
        app: AppOptions(RootCommand),
        command: CommandHelpEntry,
        command_path: []const u8,
        max_option_width: u16,
        max_subcommand_width: u16,
        option_groups: []const Group(OptionHelpEntry),
        subcommand_groups: []const Group(SubcommandHelpEntry),
        terminal_width: u16,
    };
}

pub fn InvokedCommand(comptime RootCommand: type) type {
    const count = find_subcommands(RootCommand, "") + 1;
    comptime var field_names: [count][]const u8 = undefined;
    comptime var field_values: [count]u32 = undefined;
    comptime var idx: usize = 1;
    comptime var cmd: usize = 1;
    comptime var parent: usize = 0;
    field_names[0] = "Default";
    field_values[0] = 0;
    construct_command_enum(RootCommand, "", &field_names, &field_values, &idx, &cmd, &parent);
    return @Enum(u32, .exhaustive, &field_names, &field_values);
}

pub const MissingDefinitionError = union(enum) {
    option: []const u8,
    subcommand: []const u8,
};

pub fn Option(comptime RootCommand: type) type {
    const count = find_options(RootCommand, "");
    comptime var field_names: [count][]const u8 = undefined;
    comptime var field_values: [count]u64 = undefined;
    comptime var idx: usize = 0;
    comptime var cmd: u16 = 0;
    construct_option_enum(RootCommand, "", &field_names, &field_values, &idx, &cmd);
    return @Enum(u64, .exhaustive, &field_names, &field_values);
}

pub const OptionError = struct {
    command_path: []const u8,
    kind: Kind,
    option_name: []const u8,

    pub const Kind = union(enum) {
        invalid_value: []const u8,
        missing_required,
        missing_value,
        mutually_exclusive: struct { related_option_name: []const u8 },
        unmet_dependency: struct { related_option_name: []const u8 },
    };
};

pub const OptionHelpEntry = struct {
    default_text: ?[]const u8 = null,
    deprecated: ?[]const u8 = null,
    hidden: bool = false,
    long: []const u8,
    required: bool = false,
    short: ?u8 = null,
    summary: ?[]const u8 = null,
    value_label: ?[]const u8 = null,
};

pub fn OptionInfo(comptime RootCommand: type, comptime OptionGroup: type) type {
    return struct {
        complete: ?Completer(RootCommand) = null,
        default_text: ?[]const u8 = null,
        depends_on: []const Option(RootCommand) = &.{},
        deprecated: ?[]const u8 = null,
        env_var: ?[]const u8 = null,
        group: ?OptionGroup = null,
        hidden: bool = false,
        inherited: bool = false,
        long: ?[]const u8 = null,
        long_aliases: []const []const u8 = &.{},
        mutually_exclusive_with: []const Option(RootCommand) = &.{},
        required: bool = false,
        short: ?u8 = null,
        show_default: ?bool = null,
        summary: ?[]const u8 = null,
        value_label: ?[]const u8 = null,
    };
}

pub fn ParseResult(comptime RootCommand: type) type {
    return union(enum) {
        err: ErrorResult,
        ok: SuccessResult(RootCommand),
    };
}

pub fn Subcommand(comptime RootCommand: type) type {
    const count = find_subcommands(RootCommand, "");
    comptime var field_names: [count][]const u8 = undefined;
    comptime var field_values: [count]u32 = undefined;
    comptime var idx: usize = 0;
    comptime var cmd: usize = 1;
    comptime var parent: usize = 0;
    construct_command_enum(RootCommand, "", &field_names, &field_values, &idx, &cmd, &parent);
    return @Enum(u32, .exhaustive, &field_names, &field_values);
}

pub const SubcommandHelpEntry = struct {
    deprecated: ?[]const u8 = null,
    hidden: bool = false,
    name: []const u8,
    summary: ?[]const u8 = null,
};

pub fn SubcommandInfo(comptime RootCommand: type, comptime SubcommandGroup: type) type {
    return struct {
        aliases: []const Subcommand(RootCommand) = &.{},
        complete: ?Completer(RootCommand) = null,
        deprecated: ?[]const u8 = null,
        description: ?[]const u8 = null,
        epilog: ?[]const u8 = null,
        group: ?SubcommandGroup = null,
        hidden: bool = false,
        max_args: ?usize = null,
        min_args: ?usize = null,
        name: ?[]const u8 = null,
        preserve_unmatched_short_options: bool = false,
        prolog: ?[]const u8 = null,
        subcommands_only: bool = false,
        summary: ?[]const u8 = null,
        usage: ?Usage = null,
    };
}

pub fn SuccessResult(comptime RootCommand: type) type {
    return struct {
        arena: *std.heap.ArenaAllocator,
        args: []const []const u8,
        deprecations: ?[]const Deprecation,
        invoked_command: InvokedCommand(RootCommand),
        root: *RootCommand,
        unmatched_short_options: ?[]const u8,

        pub fn deinit(self: *@This()) void {
            const backing = self.arena.child_allocator;
            self.arena.deinit();
            backing.destroy(self.arena);
        }
    };
}

pub const Usage = union(enum) {
    args: []const u8,
    full_text: []const u8,
};

pub const ValidationError = union(enum) {
    option: struct {
        message: []const u8,
        option_name: []const u8,
    },
    subcommand: struct {
        message: []const u8,
        subcommand_name: []const u8,
    },
};

fn collect_field_names(comptime T: type, comptime prefix: []const u8, option_idx: *usize, option_names: [][]const u8, subcommand_idx: *usize, subcommand_names: [][]const u8) void {
    inline for (std.meta.fields(T)) |field| {
        if (std.ascii.isUpper(field.name[0])) {
            const name = prefix ++ "." ++ field.name;
            subcommand_names[subcommand_idx.*] = name;
            subcommand_idx.* += 1;
            collect_field_names(field.type, name, option_idx, option_names, subcommand_idx, subcommand_names);
        } else {
            const name = prefix ++ "." ++ field.name;
            option_names[option_idx.*] = name;
            option_idx.* += 1;
        }
    }
}

fn construct_command_enum(comptime T: type, comptime prefix: []const u8, field_names: [][]const u8, field_values: []u32, idx: *usize, cmd: *usize, parent: *usize) void {
    for (std.meta.fields(T)) |field| {
        if (!std.ascii.isUpper(field.name[0])) {
            continue;
        }
        const name = if (prefix.len == 0) field.name else prefix ++ "_" ++ field.name;
        field_names[idx.*] = name;
        field_values[idx.*] = @as(u32, parent.*) << 16 | @as(u32, cmd.*);
        parent.* = cmd.*;
        cmd.* += 1;
        idx.* += 1;
        construct_command_enum(field.type, name, field_names, field_values, idx, cmd, parent);
    }
}

fn construct_option_enum(comptime T: type, comptime prefix: []const u8, field_names: [][]const u8, field_values: []u64, idx: *usize, cmd: *u16) void {
    for (std.meta.fields(T), 0..) |field, i| {
        if (std.ascii.isUpper(field.name[0])) {
            const name = if (prefix.len == 0) field.name ++ "_" else prefix ++ field.name ++ "_";
            cmd.* += 1;
            construct_option_enum(field.type, name, field_names, field_values, idx, cmd);
        } else {
            field_names[idx.*] = prefix ++ field.name;
            field_values[idx.*] = @as(u64, cmd.*) << 48 | @as(u64, i) << 32 | idx.*;
            idx.* += 1;
        }
    }
}

fn exit_error(app_name: []const u8, message: []const u8) noreturn {
    std.debug.print("\x1b[31mERROR: {s}: {s}\x1b[0m\n", .{ app_name, message });
    std.process.exit(1);
}

fn exit_errorf(app_name: []const u8, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("\x1b[31mERROR: {s}: ", .{app_name});
    std.debug.print(fmt, args);
    std.debug.print("\x1b[0m\n", .{});
    std.process.exit(1);
}

fn find_options(comptime T: type, comptime prefix: []const u8) usize {
    if (prefix.len == 0) {
        return find_options(T, unqualified_type_name(T));
    }
    const fields = switch (@typeInfo(T)) {
        .@"struct" => |info| info.fields,
        else => @compileError("RootCommand " ++ prefix ++ " needs to be a struct, not " ++ @typeName(T)),
    };
    var count: usize = 0;
    for (fields) |field| {
        if (std.ascii.isUpper(field.name[0])) {
            count += find_options(field.type, prefix ++ "." ++ field.name);
        } else {
            if (std.mem.startsWith(u8, field.name, "_")) {
                @compileError("RootCommand option field " ++ prefix ++ "." ++ field.name ++ " starts with an underscore");
            }
            count += 1;
        }
    }
    return count;
}

fn find_subcommands(comptime T: type, comptime prefix: []const u8) usize {
    if (prefix.len == 0) {
        return find_subcommands(T, unqualified_type_name(T));
    }
    const fields = switch (@typeInfo(T)) {
        .@"struct" => |info| info.fields,
        else => @compileError("RootCommand " ++ prefix ++ " needs to be a struct, not " ++ @typeName(T)),
    };
    var count: usize = 0;
    for (fields) |field| {
        if (!std.ascii.isUpper(field.name[0])) {
            continue;
        }
        count += 1;
        count += find_subcommands(field.type, prefix ++ "." ++ field.name);
    }
    return count;
}

fn is_invalid_long_flag(long: []const u8) ?u8 {
    for (long) |c| {
        if (c >= 'a' and c <= 'z') {
            continue;
        }
        if (c >= 'A' and c <= 'Z') {
            continue;
        }
        if (c >= '0' and c <= '9') {
            continue;
        }
        if (c == '-') {
            continue;
        }
        return c;
    }
    return null;
}

fn is_invalid_short_flag(short: u8) bool {
    if (short >= 'a' and short <= 'z') {
        return false;
    }
    if (short >= 'A' and short <= 'Z') {
        return false;
    }
    if (short >= '0' and short <= '9') {
        return false;
    }
    return true;
}

fn oom(app_name: []const u8) noreturn {
    exit_error(app_name, "out of memory");
}

fn pascal_to_kebab(comptime ident: []const u8) []const u8 {
    comptime {
        var len: usize = ident.len;
        for (ident, 0..) |c, i| {
            if (std.ascii.isUpper(c) and i > 0) {
                const prev = ident[i - 1];
                const next_is_lower = i + 1 < ident.len and std.ascii.isLower(ident[i + 1]);
                if (std.ascii.isLower(prev) or std.ascii.isDigit(prev) or (std.ascii.isUpper(prev) and next_is_lower)) {
                    len += 1;
                }
            }
        }
        var out: [len]u8 = undefined;
        var idx: usize = 0;
        for (ident, 0..) |c, i| {
            if (std.ascii.isUpper(c) and i > 0) {
                const prev = ident[i - 1];
                const next_is_lower = i + 1 < ident.len and std.ascii.isLower(ident[i + 1]);
                if (std.ascii.isLower(prev) or std.ascii.isDigit(prev) or (std.ascii.isUpper(prev) and next_is_lower)) {
                    out[idx] = '-';
                    idx += 1;
                }
            }
            out[idx] = std.ascii.toLower(c);
            idx += 1;
        }
        const result = out;
        return &result;
    }
}

fn snake_to_kebab(comptime ident: []const u8) []const u8 {
    comptime {
        var buf = ident[0..ident.len].*;
        std.mem.replaceScalar(u8, &buf, '_', '-');
        const result = buf;
        return &result;
    }
}

fn unqualified_type_name(comptime T: type) []const u8 {
    const name = @typeName(T);
    return if (std.mem.lastIndexOfScalar(u8, name, '.')) |idx| name[idx + 1 ..] else name;
}

const testing = std.testing;

fn test_pascal_conversion(comptime ident: []const u8, comptime expected: []const u8) !void {
    try testing.expectEqualStrings(comptime pascal_to_kebab(ident), expected);
}

fn test_snake_conversion(comptime ident: []const u8, comptime expected: []const u8) !void {
    try testing.expectEqualStrings(comptime snake_to_kebab(ident), expected);
}

test "enum fields for subcommands" {
    const Root = struct {
        Foo: struct {
            Bar: struct {},
            Baz: struct {
                Spam: struct {},
            },
            ignored: bool,
        },
        Help: struct {},
        lower: struct {
            Nested: struct {},
        },
    };
    const fields = @typeInfo(InvokedCommand(Root)).@"enum".fields;
    try testing.expectEqual(@as(usize, 6), fields.len);
    const expected = [_][]const u8{ "Default", "Foo", "Foo_Bar", "Foo_Baz", "Foo_Baz_Spam", "Help" };
    inline for (expected, 0..) |name, i| {
        try testing.expectEqualStrings(name, fields[i].name);
        try testing.expectEqual(@as(u16, i), fields[i].value);
    }
}

test "pascal_to_kebab" {
    try test_pascal_conversion("", "");
    try test_pascal_conversion("Foo", "foo");
    try test_pascal_conversion("FooBar", "foo-bar");
    try test_pascal_conversion("HTTP", "http");
    try test_pascal_conversion("HTTPServer", "http-server");
    try test_pascal_conversion("HTTP2Server", "http2-server");
    try test_pascal_conversion("HTTP11Server", "http11-server");
}

test "snake_to_kebab" {
    try test_snake_conversion("", "");
    try test_snake_conversion("foo", "foo");
    try test_snake_conversion("foo_bar", "foo-bar");
    try test_snake_conversion("http", "http");
    try test_snake_conversion("http_server", "http-server");
    try test_snake_conversion("http2_server", "http2-server");
    try test_snake_conversion("http11_server", "http11-server");
}

const MyApp = struct {
    Foo: struct {
        Bar: struct {
            hello: bool,
        },
        baz: bool,
    },
    spam: bool,
};

pub fn main(init: std.process.Init) !void {
    var app = App(MyApp).init(.{
        .name = "kickass",
    });

    // const fields = std.meta.tags(Option(MyApp));
    // for (fields) |field| {
    //     std.debug.print("{s}\t{d}\t{d}\n", .{ @tagName(field), @intFromEnum(field), @intFromEnum(field) & 0xFFFFFFFF });
    // }

    app.subcommand(.Foo, .{
        .summary = "Foo command",
        .name = "fx",
        // .subcommands_only = true,
        // .max_args = 1,
    });
    // app.option(.Foo_baz, .{ .summary = "option" });
    app.subcommand(.Foo_Bar, .{ .summary = "Foo Bar command" });
    app.option(.spam, .{
        .summary = "option",
        // .long = "f@s",
        .short = '1',
    });
    app.option(.Foo_Bar_hello, .{ .summary = "option" });
    // app.require_explicit_definitions();

    var result = app.parse(init);
    defer result.deinit();

    try app.print_help(init.gpa, init.io, .Foo);

    switch (result.invoked_command) {
        .Default => {
            std.debug.print("Default\n", .{});
        },
        .Foo => {
            std.debug.print("Foo\n", .{});
        },
        .Foo_Bar => {
            std.debug.print("Foo Bar\n", .{});
        },
    }
}
