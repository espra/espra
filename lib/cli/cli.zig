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
        print_help: ?*const fn (Allocator, *std.Io.Writer, HelpContext) anyerror!void = null,
        max_args: ?usize = null,
        min_args: ?usize = null,
        name: []const u8,
        preserve_unmatched_short_options: bool = false,
        prolog: ?[]const u8 = null,
        show_defaults: ?bool = null,
        supports_positional_args: ?bool = null,
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

    const ResolvedOption = struct {
        complete: ?Completer(RootCommand) = null,
        decode: *const fn (Allocator, *RootCommand, DecodeSource) ?[]const u8,
        default_text: ?[]const u8 = null,
        depends_on: []const usize = &.{},
        deprecated: ?[]const u8 = null,
        dotted_path: []const u8,
        env_var: ?[]const u8 = null,
        group: ?OptionGroup = null,
        has_default: bool,
        hidden: bool = false,
        id: usize,
        inherited: bool = false,
        is_alias: bool = false,
        kind: ValueKind,
        long: []const u8,
        mutually_exclusive_with: []const usize = &.{},
        parent_command: usize = 0,
        required: bool = false,
        show_default: ?bool = null,
        summary: ?[]const u8 = null,
        value_label: ?[]const u8 = null,
    };

    const ResolvedCommand = struct {
        const Self = @This();
        aliases: []*Self = &.{},
        complete: ?Completer(RootCommand) = null,
        deprecated: ?[]const u8 = null,
        description: ?[]const u8 = null,
        dotted_path: []const u8,
        epilog: ?[]const u8 = null,
        group: ?SubcommandGroup = null,
        hidden: bool = false,
        id: usize,
        is_alias: bool = false,
        is_root: bool = false,
        is_stub: bool = false,
        long_flags: std.StringHashMapUnmanaged(*ResolvedOption) = .empty,
        max_args: ?usize = null,
        min_args: ?usize = null,
        name: []const u8,
        preserve_unmatched_short_options: bool = false,
        prolog: ?[]const u8 = null,
        short_flags: std.AutoHashMapUnmanaged(u8, *ResolvedOption) = .empty,
        subcommands: std.StringHashMapUnmanaged(*Self) = .empty,
        summary: ?[]const u8 = null,
        supports_positional_args: ?bool = null,
        usage: ?Usage = null,
    };

    const Resolved = struct {
        options: [options_count]*ResolvedOption,
        root: *ResolvedCommand,
        subcommands: [subcommands_count]*ResolvedCommand,
    };

    const ResolvedResult = union(enum) {
        ok: Resolved,
        err: ValidationError,
    };

    const Alias = struct {
        aliases: []const []const u8,
        subcommand: *ResolvedCommand,
    };

    comptime var option_idx: usize = 0;
    comptime var option_meta: [options_count]OptionMeta(RootCommand) = undefined;
    comptime var subcommand_idx: usize = 0;
    comptime var subcommand_meta: [subcommands_count]SubcommandMeta = undefined;
    comptime var parent_command_idx: usize = 0;
    comptime construct_meta(
        RootCommand,
        RootCommand,
        unqualified_type_name(RootCommand),
        &.{},
        &option_idx,
        &option_meta,
        &subcommand_idx,
        &subcommand_meta,
        &parent_command_idx,
    );

    return struct {
        app_options: AppOptions(RootCommand),
        option_meta: [options_count]OptionMeta(RootCommand),
        options: [options_count]?OptionInfo(RootCommand, OptionGroup),
        require_explicit: bool,
        subcommand_meta: [subcommands_count]SubcommandMeta,
        subcommands: [subcommands_count]?SubcommandInfo(RootCommand, SubcommandGroup),

        const Self = @This();

        pub fn init(options: AppOptions(RootCommand)) Self {
            return .{
                .app_options = options,
                .option_meta = option_meta,
                .options = .{null} ** options_count,
                .require_explicit = false,
                .subcommand_meta = subcommand_meta,
                .subcommands = .{null} ** subcommands_count,
            };
        }

        pub fn option(self: *Self, opt: Option(RootCommand), info: OptionInfo(RootCommand, OptionGroup)) void {
            self.options[@intFromEnum(opt)] = info;
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
                        print_deprecations(allocator, proc.io, self.app_options.name, deprecations, self.app_options.print_deprecations orelse default_print_deprecations);
                    }
                    return r;
                },
                .err => |e| {
                    print_error(allocator, proc.io, self.app_options.name, e, self.app_options.print_error orelse default_print_error);
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
            const resolved = switch (self.resolve_definitions(allocator)) {
                .ok => |r| r,
                .err => |e| {
                    return .{
                        .err = .{ .validation = e },
                    };
                },
            };
            _ = resolved;
            _ = args;
            const root = allocator.create(RootCommand) catch oom(self.app_options.name);
            root.* = std.mem.zeroInit(RootCommand, .{});
            return .{
                .ok = .{
                    .arena = arena,
                    .args = &.{},
                    .deprecations = null,
                    .invoked_command = .Default,
                    .root = root,
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
            self.subcommands[@intFromEnum(cmd)] = info;
        }

        fn build_help_context(self: *Self, cmd: InvokedCommand(RootCommand)) HelpContext {
            _ = cmd;
            return .{
                .app_name = self.app_options.name,
                .command = .{
                    .description = null,
                    .epilog = null,
                    .prolog = null,
                    .summary = null,
                    .usage = null,
                },
                .heading_style = self.app_options.help_heading_style,
                .heading_style_end = self.app_options.help_heading_style_end,
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
                    return .{ .subcommand = self.subcommand_meta[i].dotted_path };
                }
            }
            for (0..options_count) |i| {
                if (self.options[i] == null) {
                    return .{ .option = self.option_meta[i].dotted_path };
                }
            }
            return null;
        }

        fn resolve_definitions(self: *Self, allocator: Allocator) ResolvedResult {
            const root = allocator.create(ResolvedCommand) catch oom(self.app_options.name);
            root.* = .{
                .complete = self.app_options.complete,
                .description = self.app_options.description,
                .dotted_path = unqualified_type_name(RootCommand),
                .epilog = self.app_options.epilog,
                .id = 0,
                .is_root = true,
                .max_args = self.app_options.max_args,
                .min_args = self.app_options.min_args,
                .name = self.app_options.name,
                .preserve_unmatched_short_options = self.app_options.preserve_unmatched_short_options,
                .prolog = self.app_options.prolog,
                .summary = self.app_options.summary,
                .supports_positional_args = self.app_options.supports_positional_args,
                .usage = self.app_options.usage,
            };
            var aliased: std.ArrayList(Alias) = .empty;
            var resolved = Resolved{
                .options = .{undefined} ** options_count,
                .root = root,
                .subcommands = .{undefined} ** subcommands_count,
            };
            for (self.subcommands, self.subcommand_meta, 0..) |s, meta, i| {
                const info = s orelse SubcommandInfo(RootCommand, SubcommandGroup){};
                const cmd = allocator.create(ResolvedCommand) catch oom(self.app_options.name);
                cmd.* = .{
                    .complete = info.complete,
                    .deprecated = info.deprecated,
                    .description = info.description,
                    .dotted_path = meta.dotted_path,
                    .epilog = info.epilog,
                    .group = info.group,
                    .hidden = info.hidden,
                    .id = i + 1,
                    .max_args = info.max_args,
                    .min_args = info.min_args,
                    .name = info.name orelse meta.name,
                    .preserve_unmatched_short_options = info.preserve_unmatched_short_options,
                    .prolog = info.prolog,
                    .summary = info.summary,
                    .supports_positional_args = info.supports_positional_args,
                    .usage = info.usage,
                };
                const parent = if (meta.parent_command == 0)
                    resolved.root
                else
                    resolved.subcommands[meta.parent_command - 1];
                if (parent.subcommands.get(cmd.name)) |existing| {
                    const this_status = if (info.name == null)
                        "inferred "
                    else
                        "";
                    const existing_status = if (existing.is_stub)
                        "stubbed alias"
                    else if (existing.is_alias)
                        "alias"
                    else if (self.subcommands[existing.id - 1]) |existing_info|
                        if (existing_info.name == null)
                            "name inferred"
                        else
                            "name defined"
                    else
                        "name inferred";
                    return .{
                        .err = .{
                            .subcommand = .{
                                .message = std.fmt.allocPrint(allocator, "{s}subcommand name conflicts with {s} for {s}: {s}", .{ this_status, existing_status, existing.dotted_path, cmd.name }) catch oom(self.app_options.name),
                                .subcommand_name = meta.dotted_path,
                            },
                        },
                    };
                }
                if (cmd.name.len == 0) {
                    return .{
                        .err = .{
                            .subcommand = .{
                                .message = "`name` is an empty string",
                                .subcommand_name = cmd.dotted_path,
                            },
                        },
                    };
                }
                if (cmd.supports_positional_args == false) {
                    if (cmd.min_args) |min_args| {
                        if (min_args > 0) {
                            return .{
                                .err = .{
                                    .subcommand = .{
                                        .message = "cannot set `min_args` while `supports_positional_args` is false",
                                        .subcommand_name = cmd.dotted_path,
                                    },
                                },
                            };
                        }
                    }
                    if (cmd.max_args) |max_args| {
                        if (max_args > 0) {
                            return .{
                                .err = .{
                                    .subcommand = .{
                                        .message = "cannot set `max_args` while `supports_positional_args` is false",
                                        .subcommand_name = cmd.dotted_path,
                                    },
                                },
                            };
                        }
                    }
                }
                parent.subcommands.put(allocator, cmd.name, cmd) catch oom(self.app_options.name);
                if (info.aliases.len > 0) {
                    aliased.append(allocator, .{
                        .aliases = info.aliases,
                        .subcommand = cmd,
                    }) catch oom(self.app_options.name);
                }
                resolved.subcommands[i] = cmd;
            }
            // default_text: ?[]const u8 = null,
            // required: bool = false,
            // show_default: ?bool = null,

            // supports_cli_text: bool,
            for (self.options, self.option_meta, 0..) |o, meta, i| {
                const info = o orelse OptionInfo(RootCommand, OptionGroup){};
                const opt = allocator.create(ResolvedOption) catch oom(self.app_options.name);
                opt.* = .{
                    .complete = info.complete,
                    .decode = meta.decode,
                    // .default_text = info.default_text orelse meta.default_text,
                    .deprecated = info.deprecated,
                    .dotted_path = meta.dotted_path,
                    .group = info.group,
                    .has_default = meta.has_default,
                    .hidden = info.hidden,
                    .id = i,
                    .inherited = info.inherited,
                    .kind = meta.kind,
                    .long = info.long orelse meta.long,
                    .parent_command = meta.parent_command,
                    // .required = info.required,
                    // .show_default = info.show_default,
                    .summary = info.summary,
                    .value_label = info.value_label,
                };
                if (info.env_var) |env_var| {
                    if (env_var.len > 0) {
                        opt.env_var = env_var;
                    }
                } else if (self.app_options.env_var_prefix) |prefix| {
                    if (prefix.len > 0) {
                        const suffix = kebab_to_screaming_snake(allocator, opt.long) catch oom(self.app_options.name);
                        opt.env_var = std.fmt.allocPrint(allocator, "{s}_{s}", .{ prefix, suffix }) catch oom(self.app_options.name);
                    }
                }
                if (needs_default_text(meta.kind, self.app_options.show_defaults, info.show_default)) {
                    if (!meta.supports_cli_text) {
                        return .{
                            .err = .{
                                .option = .{
                                    .message = "missing default text for custom data type without a `format` method",
                                    .option_name = meta.dotted_path,
                                },
                            },
                        };
                    }
                }
                const depends_on = allocator.alloc(usize, info.depends_on.len) catch oom(self.app_options.name);
                for (info.depends_on, 0..) |dep, j| {
                    depends_on[j] = @intFromEnum(dep);
                }
                opt.depends_on = depends_on;
                const mutually_exclusive_with = allocator.alloc(usize, info.mutually_exclusive_with.len) catch oom(self.app_options.name);
                for (info.mutually_exclusive_with, 0..) |dep, j| {
                    mutually_exclusive_with[j] = @intFromEnum(dep);
                }
                opt.mutually_exclusive_with = mutually_exclusive_with;
                const cmd = if (opt.parent_command == 0)
                    root
                else
                    resolved.subcommands[opt.parent_command - 1];
                if (info.short) |short| {
                    if (is_invalid_short_flag(short)) {
                        return .{
                            .err = .{
                                .option = .{
                                    .message = std.fmt.allocPrint(allocator, "`short` value is invalid: \"{c}\" (0x{x:0>2})", .{ short, short }) catch oom(self.app_options.name),
                                    .option_name = opt.dotted_path,
                                },
                            },
                        };
                    }
                    if (cmd.short_flags.get(short)) |existing| {
                        return .{
                            .err = .{
                                .option = .{
                                    .message = std.fmt.allocPrint(allocator, "`short` value conflicts with existing definition for {s}: \"{c}\"", .{ existing.dotted_path, short }) catch oom(self.app_options.name),
                                    .option_name = opt.dotted_path,
                                },
                            },
                        };
                    }
                    cmd.short_flags.put(allocator, short, opt) catch oom(self.app_options.name);
                }
                if (opt.long.len == 0) {
                    return .{
                        .err = .{
                            .option = .{
                                .message = "`long` is an empty string",
                                .option_name = opt.dotted_path,
                            },
                        },
                    };
                }
                if (opt.long[0] == '-') {
                    return .{
                        .err = .{
                            .option = .{
                                .message = "`long` starts with a hyphen",
                                .option_name = opt.dotted_path,
                            },
                        },
                    };
                }
                const this_status = if (info.long == null)
                    "inferred "
                else
                    "";
                if (opt.long.len == 1) {
                    return .{
                        .err = .{
                            .option = .{
                                .message = std.fmt.allocPrint(allocator, "{s}`long` is a single character", .{this_status}) catch oom(self.app_options.name),
                                .option_name = opt.dotted_path,
                            },
                        },
                    };
                }
                if (is_invalid_long_flag(opt.long)) |char| {
                    return .{
                        .err = .{
                            .option = .{
                                .message = std.fmt.allocPrint(allocator, "{s}`long` contains an invalid character: \"{c}\" (0x{x:0>2})", .{ this_status, char, char }) catch oom(self.app_options.name),
                                .option_name = opt.dotted_path,
                            },
                        },
                    };
                }
                if (cmd.long_flags.get(opt.long)) |existing| {
                    const existing_status = if (existing.is_alias)
                        "alias"
                    else
                        "definition";
                    return .{
                        .err = .{
                            .option = .{
                                .message = std.fmt.allocPrint(allocator, "{s}`long` value conflicts with existing {s} for {s}: \"{s}\"", .{ this_status, existing_status, existing.dotted_path, opt.long }) catch oom(self.app_options.name),
                                .option_name = opt.dotted_path,
                            },
                        },
                    };
                }
                cmd.long_flags.put(allocator, opt.long, opt) catch oom(self.app_options.name);
                for (info.long_aliases) |alias| {
                    if (alias.len == 0) {
                        return .{
                            .err = .{
                                .option = .{
                                    .message = "`long_alias` value is an empty string",
                                    .option_name = opt.dotted_path,
                                },
                            },
                        };
                    }
                    if (alias[0] == '-') {
                        return .{
                            .err = .{
                                .option = .{
                                    .message = "`long_alias` value starts with a hyphen",
                                    .option_name = opt.dotted_path,
                                },
                            },
                        };
                    }
                    if (alias.len == 1) {
                        return .{
                            .err = .{
                                .option = .{
                                    .message = "`long_alias` value is a single character",
                                    .option_name = opt.dotted_path,
                                },
                            },
                        };
                    }
                    if (is_invalid_long_flag(alias)) |char| {
                        return .{
                            .err = .{
                                .option = .{
                                    .message = std.fmt.allocPrint(allocator, "`long_alias` value contains an invalid character: \"{c}\" (0x{x:0>2})", .{ char, char }) catch oom(self.app_options.name),
                                    .option_name = opt.dotted_path,
                                },
                            },
                        };
                    }
                    const clone = allocator.create(ResolvedOption) catch oom(self.app_options.name);
                    clone.* = opt.*;
                    clone.hidden = true;
                    clone.is_alias = true;
                    if (cmd.long_flags.get(alias)) |existing| {
                        const existing_status = if (existing.is_alias)
                            "alias"
                        else
                            "definition";
                        return .{
                            .err = .{
                                .option = .{
                                    .message = std.fmt.allocPrint(allocator, "`long_alias` value conflicts with existing {s} for {s}: \"{s}\"", .{ existing_status, existing.dotted_path, alias }) catch oom(self.app_options.name),
                                    .option_name = opt.dotted_path,
                                },
                            },
                        };
                    }
                    cmd.long_flags.put(allocator, alias, clone) catch oom(self.app_options.name);
                }
                resolved.options[i] = opt;
            }
            // depends_on value {}
            // mutually_exclusive_with value {}
            // field {} needs to either be required or have a default value
            // shadowed inherited option
            // propagate inherited options (+ to aliased subcommands)
            for (aliased.items) |a| {
                var aliases: std.ArrayList(*ResolvedCommand) = .empty;
                for (a.aliases) |alias| {
                    const clone = allocator.create(ResolvedCommand) catch oom(self.app_options.name);
                    clone.* = a.subcommand.*;
                    clone.is_alias = true;
                    var parent = root;
                    var it = std.mem.splitScalar(u8, alias, ' ');
                    var alias_set = false;
                    while (it.next()) |part| {
                        if (part.len == 0) {
                            continue;
                        }
                        const is_last = it.peek() == null;
                        if (is_last) {
                            if (parent.subcommands.get(part)) |existing| {
                                const existing_status = if (existing.is_stub)
                                    "stubbed alias"
                                else if (existing.is_alias)
                                    "alias"
                                else if (self.subcommands[existing.id - 1]) |existing_info| // NOTE(tav): This depends on the prior check for is_stub for safety.
                                    if (existing_info.name == null)
                                        "name inferred"
                                    else
                                        "name defined"
                                else
                                    "name inferred";
                                return .{
                                    .err = .{
                                        .subcommand = .{
                                            .message = std.fmt.allocPrint(allocator, "alias conflicts with {s} for {s}: {s}", .{ existing_status, existing.dotted_path, alias }) catch oom(self.app_options.name),
                                            .subcommand_name = clone.dotted_path,
                                        },
                                    },
                                };
                            }
                            clone.name = part;
                            parent.subcommands.put(allocator, part, clone) catch oom(self.app_options.name);
                            alias_set = true;
                            aliases.append(allocator, clone) catch oom(self.app_options.name);
                        } else {
                            if (parent.subcommands.get(part)) |existing| {
                                parent = existing;
                            } else {
                                const child = allocator.create(ResolvedCommand) catch oom(self.app_options.name);
                                child.* = .{
                                    .dotted_path = clone.dotted_path,
                                    .hidden = true,
                                    .id = 0,
                                    .is_stub = true,
                                    .name = part,
                                    .supports_positional_args = false,
                                };
                                parent.subcommands.put(allocator, part, child) catch oom(self.app_options.name);
                                parent = child;
                            }
                        }
                    }
                    if (!alias_set) {
                        return .{
                            .err = .{
                                .subcommand = .{
                                    .message = std.fmt.allocPrint(allocator, "invalid alias: `{s}`", .{alias}) catch oom(self.app_options.name),
                                    .subcommand_name = clone.dotted_path,
                                },
                            },
                        };
                    }
                }
                a.subcommand.aliases = aliases.toOwnedSlice() catch oom(self.app_options.name);
            }
            return .{ .ok = resolved };
        }

        fn run_completion(self: *Self, shell: []const u8) void {
            _ = self;
            _ = shell;
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

const DecodeSource = union(enum) {
    arg: []const u8,
    args: []const []const u8,
    env: []const u8,
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

pub const HelpContext = struct {
    app_name: []const u8,
    command: CommandHelpEntry,
    command_path: []const u8,
    heading_style: []const u8,
    heading_style_end: []const u8,
    max_option_width: u16,
    max_subcommand_width: u16,
    option_groups: []const Group(OptionHelpEntry),
    subcommand_groups: []const Group(SubcommandHelpEntry),
    terminal_width: u16,
};

pub fn InvokedCommand(comptime RootCommand: type) type {
    const count = find_subcommands(RootCommand, "") + 1;
    comptime var field_names: [count][]const u8 = undefined;
    comptime var field_values: [count]u16 = undefined;
    comptime var idx: usize = 1;
    field_names[0] = "Default";
    field_values[0] = 0;
    construct_command_enum(RootCommand, "", &field_names, &field_values, &idx);
    return @Enum(u16, .exhaustive, &field_names, &field_values);
}

pub const MissingDefinitionError = union(enum) {
    option: []const u8,
    subcommand: []const u8,
};

pub fn Option(comptime RootCommand: type) type {
    const count = find_options(RootCommand, "");
    comptime var field_names: [count][]const u8 = undefined;
    comptime var field_values: [count]u32 = undefined;
    comptime var idx: usize = 0;
    construct_option_enum(RootCommand, "", &field_names, &field_values, &idx);
    return @Enum(u32, .exhaustive, &field_names, &field_values);
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
    comptime var field_values: [count]u16 = undefined;
    comptime var idx: usize = 0;
    construct_command_enum(RootCommand, "", &field_names, &field_values, &idx);
    return @Enum(u16, .exhaustive, &field_names, &field_values);
}

pub const SubcommandHelpEntry = struct {
    deprecated: ?[]const u8 = null,
    hidden: bool = false,
    name: []const u8,
    summary: ?[]const u8 = null,
};

pub fn SubcommandInfo(comptime RootCommand: type, comptime SubcommandGroup: type) type {
    return struct {
        aliases: []const []const u8 = &.{},
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
        summary: ?[]const u8 = null,
        supports_positional_args: ?bool = null,
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

pub const WrapSpec = struct {
    indent: u32 = 0,
    start_col: u32 = 0,
    width: u32 = 80,
};

fn OptionMeta(comptime RootCommand: type) type {
    return struct {
        decode: *const fn (Allocator, *RootCommand, DecodeSource) ?[]const u8,
        default_text: ?[]const u8,
        dotted_path: []const u8,
        field_path: []const []const u8,
        has_default: bool,
        kind: ValueKind,
        long: []const u8,
        parent_command: usize,
        supports_cli_text: bool,
    };
}

const SubcommandMeta = struct {
    dotted_path: []const u8,
    name: []const u8,
    parent_command: usize, // NOTE(tav): offset by 1 as 0 is reserved for the root command
};

const ValueKind = union(enum) {
    const Self = @This();
    bool,
    interface,
    float,
    int,
    optional: *const Self,
    slice: *const Self,
    string,
    string_enum,

    fn from_type(comptime T: type, comptime dotted_path: []const u8, comptime nested_slice: bool, comptime nested_optional: bool) Self {
        return switch (@typeInfo(T)) {
            .bool => {
                if (nested_slice) {
                    @compileError("Unsupported type for cli.App field found in " ++ dotted_path ++ ": bool slice");
                }
                return .bool;
            },
            .@"enum" => {
                if (match_cli_interface(T, dotted_path)) {
                    return .interface;
                }
                return .string_enum;
            },
            .float, .comptime_float => .float,
            .int, .comptime_int => .int,
            .optional => |info| {
                if (nested_optional) {
                    @compileError("Unsupported type for cli.App field found in " ++ dotted_path ++ ": " ++ @typeName(T) ++ ": nested optionals");
                }
                if (nested_slice) {
                    @compileError("Unsupported type for cli.App field found in " ++ dotted_path ++ ": " ++ @typeName(T) ++ ": nested optional within a slice");
                }
                return .{ .optional = &from_type(info.child, dotted_path, nested_slice, true) };
            },
            .pointer => |info| {
                if (info.size == .slice and info.child == u8) {
                    return .string;
                }
                if (info.size == .slice) {
                    if (nested_slice) {
                        @compileError("Unsupported type for cli.App field found in " ++ dotted_path ++ ": " ++ @typeName(T) ++ ": nested slices");
                    }
                    if (nested_optional) {
                        @compileError("Unsupported type for cli.App field found in " ++ dotted_path ++ ": " ++ @typeName(T) ++ ": optional non-string slices");
                    }
                    return .{ .slice = &from_type(info.child, dotted_path, true, nested_optional) };
                }
                @compileError("Unsupported type for cli.App field found in " ++ dotted_path ++ ": " ++ @typeName(T) ++ ": non-slice pointer");
            },
            .@"struct" => |info| {
                if (info.layout != .auto) {
                    @compileError("Unsupported struct layout for cli.App field found in " ++ dotted_path ++ ": " ++ @typeName(T) ++ ": " ++ @tagName(info.layout));
                }
                if (info.is_tuple) {
                    @compileError("Unsupported struct type for cli.App field found in " ++ dotted_path ++ ": " ++ @typeName(T) ++ ": tuple");
                }
                if (!match_cli_interface(T, dotted_path)) {
                    @compileError("Struct type " ++ @typeName(T) ++ " for cli.App field found in " ++ dotted_path ++ " does not have a decode_cli_arg function");
                }
                return .interface;
            },
            else => @compileError("Unsupported type for cli.App field found in " ++ dotted_path ++ ": " ++ @typeName(T)),
        };
    }

    fn match_cli_interface(comptime T: type, comptime dotted_path: []const u8) bool {
        if (@hasDecl(T, "cli_text")) {
            validate_cli_text(T, dotted_path);
        }
        if (@hasDecl(T, "decode_cli_arg")) {
            validate_decode_cli_arg(T, dotted_path);
            if (@hasDecl(T, "decode_cli_env")) {
                validate_decode_cli_env(T, dotted_path);
            }
            return true;
        }
        return false;
    }

    fn validate_cli_text(comptime T: type, comptime dotted_path: []const u8) void {
        const err = "Invalid cli interface definition for " ++ @typeName(T) ++ " found in " ++ dotted_path ++ ": .cli_text ";
        const decl = @typeInfo(@TypeOf(T.cli_text));
        if (decl != .@"fn") {
            @compileError(err ++ "needs to be a method, not " ++ @tagName(decl));
        }
        const func = decl.@"fn";
        if (func.params.len != 2) {
            @compileError(err ++ "needs to take exactly 2 parameters: (self: " ++ @typeName(T) ++ ", allocator: mem.Allocator), not " ++ std.fmt.comptimePrint("{d}", .{func.params.len}));
        }
        if (func.params[0].type) |t| {
            if (t != T) {
                @compileError(err ++ "first parameter must be " ++ @typeName(T) ++ ", not " ++ @typeName(t));
            }
        }
        if (func.params[1].type) |t| {
            if (t != Allocator) {
                @compileError(err ++ "second parameter must be mem.Allocator, not " ++ @typeName(t));
            }
        }
        const Return = func.return_type orelse @compileError(err ++ "must have a concrete return type");
        switch (@typeInfo(Return)) {
            .error_union => |info| {
                if (info.payload != []const u8) {
                    @compileError(err ++ "must return ![]const u8, not " ++ @typeName(Return));
                }
            },
            else => @compileError(err ++ "must return ![]const u8, not " ++ @typeName(Return)),
        }
    }

    fn validate_decode_cli_arg(comptime T: type, comptime dotted_path: []const u8) void {
        const err = "Invalid cli interface definition for " ++ @typeName(T) ++ " found in " ++ dotted_path ++ ": .decode_cli_arg ";
        const decl = @typeInfo(@TypeOf(T.decode_cli_arg));
        if (decl != .@"fn") {
            @compileError(err ++ "needs to be a method, not " ++ @tagName(decl));
        }
        const func = decl.@"fn";
        if (func.params.len != 2) {
            @compileError(err ++ "needs to take exactly 2 parameters: (allocator: mem.Allocator, raw: []const u8), not " ++ std.fmt.comptimePrint("{d}", .{func.params.len}));
        }
        if (func.params[0].type) |t| {
            if (t != Allocator) {
                @compileError(err ++ "first parameter must be mem.Allocator, not " ++ @typeName(t));
            }
        }
        if (func.params[1].type) |t| {
            if (t != []const u8) {
                @compileError(err ++ "second parameter must be []const u8, not " ++ @typeName(t));
            }
        }
        const Return = func.return_type orelse @compileError(err ++ "must have a concrete return type");
        if (Return != DecodeResult(T)) {
            @compileError(err ++ "must return cli.DecodeResult(" ++ @typeName(T) ++ "), not " ++ @typeName(Return));
        }
    }

    fn validate_decode_cli_env(comptime T: type, comptime dotted_path: []const u8) void {
        const err = "Invalid cli interface definition for " ++ @typeName(T) ++ " found in " ++ dotted_path ++ ": .decode_cli_env ";
        const decl = @typeInfo(@TypeOf(T.decode_cli_env));
        if (decl != .@"fn") {
            @compileError(err ++ "needs to be a method, not " ++ @tagName(decl));
        }
        const func = decl.@"fn";
        if (func.params.len != 2) {
            @compileError(err ++ "needs to take exactly 2 parameters: (allocator: mem.Allocator, raw: []const u8), not " ++ std.fmt.comptimePrint("{d}", .{func.params.len}));
        }
        if (func.params[0].type) |t| {
            if (t != Allocator) {
                @compileError(err ++ "first parameter must be mem.Allocator, not " ++ @typeName(t));
            }
        }
        if (func.params[1].type) |t| {
            if (t != []const u8) {
                @compileError(err ++ "second parameter must be []const u8, not " ++ @typeName(t));
            }
        }
        const Return = func.return_type orelse @compileError(err ++ "must have a concrete return type");
        if (Return != DecodeResult(T)) {
            @compileError(err ++ "must return cli.DecodeResult(" ++ @typeName(T) ++ "), not " ++ @typeName(Return));
        }
    }
};

pub fn write_wrapped(writer: *std.Io.Writer, text: []const u8, spec: WrapSpec) !void {
    var col = spec.start_col;
    if (col < spec.indent) {
        _ = try writer.splatByte(' ', spec.indent - col);
        col = spec.indent;
    }
    var first = true;
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and text[i] == ' ') : (i += 1) {}
        const word_start = i;
        while (i < text.len and text[i] != ' ' and text[i] != '\n') : (i += 1) {}
        const word = text[word_start..i];
        if (word.len == 0) {
            if (i < text.len and text[i] == '\n') {
                try writer.writeByte('\n');
                _ = try writer.splatByte(' ', spec.indent);
                col = spec.indent;
                first = true;
                i += 1;
            }
            continue;
        }
        if (first) {
            try writer.writeAll(word);
            col += @intCast(word.len);
            first = false;
        } else if (col + 1 + @as(u32, @intCast(word.len)) > spec.width) {
            try writer.writeByte('\n');
            _ = try writer.splatByte(' ', spec.indent);
            try writer.writeAll(word);
            col = spec.indent + @as(u32, @intCast(word.len));
        } else {
            try writer.writeByte(' ');
            try writer.writeAll(word);
            col += 1 + @as(u32, @intCast(word.len));
        }
    }
}

fn construct_decode(comptime RootCommand: type, comptime T: type, comptime kind: ValueKind, comptime path: []const []const u8) *const fn (Allocator, *RootCommand, DecodeSource) ?[]const u8 {
    return struct {
        fn decode(allocator: Allocator, root: *RootCommand, source: DecodeSource) ?[]const u8 {
            const ptr = get_root_field_ptr(RootCommand, T, root, path);
            switch (source) {
                .arg => |val| return decode_cli_arg(T, kind, allocator, ptr, val),
                .args => |vals| {
                    switch (kind) {
                        .slice => |inner| {
                            const Inner = std.meta.Child(T);
                            var list: std.ArrayList(Inner) = .empty;
                            for (vals) |val| {
                                const elem = blk: switch (inner.*) {
                                    .bool => unreachable,
                                    .float => {
                                        break :blk std.fmt.parseFloat(Inner, val) catch return "invalid float value";
                                    },
                                    .int => {
                                        break :blk std.fmt.parseInt(Inner, val, 10) catch return "invalid int value";
                                    },
                                    .interface => {
                                        const result = Inner.decode_cli_arg(allocator, val);
                                        switch (result) {
                                            .ok => |elem| break :blk elem,
                                            .err => |e| return e,
                                        }
                                    },
                                    .optional => unreachable,
                                    .slice => unreachable,
                                    .string => break :blk val,
                                    .string_enum => break :blk std.meta.stringToEnum(Inner, val) orelse return "invalid enum variant",
                                };
                                list.append(allocator, elem) catch return "out of memory";
                            }
                            ptr.* = list.items;
                            return null;
                        },
                        else => unreachable,
                    }
                },
                .env => |val| return decode_cli_env(T, kind, allocator, ptr, val),
            }
            return null;
        }
    }.decode;
}

fn construct_meta(comptime RootCommand: type, comptime T: type, comptime prefix: []const u8, comptime path: []const []const u8, option_idx: *usize, option_meta: []OptionMeta(RootCommand), subcommand_idx: *usize, subcommand_meta: []SubcommandMeta, parent_command_idx: *usize) void {
    inline for (std.meta.fields(T)) |field| {
        if (std.ascii.isUpper(field.name[0])) {
            const name = prefix ++ "." ++ field.name;
            const parent_command = parent_command_idx.*;
            subcommand_meta[subcommand_idx.*] = .{
                .dotted_path = name,
                .name = pascal_to_kebab(field.name),
                .parent_command = parent_command,
            };
            subcommand_idx.* += 1;
            parent_command_idx.* = subcommand_idx.*;
            construct_meta(RootCommand, field.type, name, path ++ &[_][]const u8{field.name}, option_idx, option_meta, subcommand_idx, subcommand_meta, parent_command_idx);
            parent_command_idx.* = parent_command;
        } else {
            const field_path = path ++ &[_][]const u8{field.name};
            const name = prefix ++ "." ++ field.name;
            const kind = ValueKind.from_type(field.type, name, false, false);
            const has_default = field.default_value_ptr != null;
            const default_text = if (has_default) get_default_text(kind, field) else null;
            option_meta[option_idx.*] = .{
                .decode = construct_decode(RootCommand, field.type, kind, field_path),
                .default_text = default_text,
                .dotted_path = name,
                .field_path = field_path,
                .has_default = has_default,
                .kind = kind,
                .long = snake_to_kebab(field.name),
                .parent_command = parent_command_idx.*,
                .supports_cli_text = supports_cli_text(field.type, kind),
            };
            option_idx.* += 1;
        }
    }
}

fn construct_command_enum(comptime T: type, comptime prefix: []const u8, field_names: [][]const u8, field_values: []u16, idx: *usize) void {
    for (std.meta.fields(T)) |field| {
        if (!std.ascii.isUpper(field.name[0])) {
            continue;
        }
        const name = if (prefix.len == 0) field.name else prefix ++ "_" ++ field.name;
        field_names[idx.*] = name;
        field_values[idx.*] = idx.*;
        idx.* += 1;
        construct_command_enum(field.type, name, field_names, field_values, idx);
    }
}

fn construct_option_enum(comptime T: type, comptime prefix: []const u8, field_names: [][]const u8, field_values: []u32, idx: *usize) void {
    for (std.meta.fields(T)) |field| {
        if (std.ascii.isUpper(field.name[0])) {
            const name = if (prefix.len == 0) field.name ++ "_" else prefix ++ field.name ++ "_";
            construct_option_enum(field.type, name, field_names, field_values, idx);
        } else {
            field_names[idx.*] = prefix ++ field.name;
            field_values[idx.*] = idx.*;
            idx.* += 1;
        }
    }
}

fn decode_bool(allocator: Allocator, value: []const u8) DecodeResult(bool) {
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "yes") or std.mem.eql(u8, value, "on")) {
        return .{ .ok = true };
    }
    if (std.mem.eql(u8, value, "") or std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "no") or std.mem.eql(u8, value, "off")) {
        return .{ .ok = false };
    }
    const err = std.fmt.allocPrint(allocator, "invalid bool value: {s}", .{value}) catch "invalid bool value";
    return .{ .err = err };
}

fn decode_cli_arg(comptime T: type, comptime kind: ValueKind, allocator: Allocator, ptr: *T, val: []const u8) ?[]const u8 {
    switch (kind) {
        .bool => ptr.* = true,
        .float => ptr.* = std.fmt.parseFloat(T, val) catch return "invalid float value",
        .int => ptr.* = std.fmt.parseInt(T, val, 10) catch return "invalid int value",
        .interface => {
            const result = T.decode_cli_arg(allocator, val);
            switch (result) {
                .ok => |v| ptr.* = v,
                .err => |e| return e,
            }
        },
        .optional => |inner| {
            const Inner = std.meta.Child(T);
            var raw: Inner = undefined;
            const err = decode_cli_arg(Inner, inner.*, allocator, &raw, val);
            if (err == null) {
                ptr.* = raw;
            }
            return err;
        },
        .slice => unreachable,
        .string => ptr.* = val,
        .string_enum => ptr.* = std.meta.stringToEnum(T, val) orelse return "invalid enum variant",
    }
    return null;
}

fn decode_cli_env(comptime T: type, comptime kind: ValueKind, allocator: Allocator, ptr: *T, val: []const u8) ?[]const u8 {
    switch (kind) {
        .bool => {
            const result = decode_bool(allocator, val);
            switch (result) {
                .ok => |v| ptr.* = v,
                .err => |e| return e,
            }
        },
        .float => ptr.* = std.fmt.parseFloat(T, val) catch return "invalid float value",
        .int => ptr.* = std.fmt.parseInt(T, val, 10) catch return "invalid int value",
        .interface => {
            if (@hasDecl(T, "decode_cli_env")) {
                const result = T.decode_cli_env(allocator, val);
                switch (result) {
                    .ok => |v| ptr.* = v,
                    .err => |e| return e,
                }
            } else {
                const result = T.decode_cli_arg(allocator, val);
                switch (result) {
                    .ok => |v| ptr.* = v,
                    .err => |e| return e,
                }
            }
        },
        .optional => |inner| {
            const Inner = std.meta.Child(T);
            return decode_cli_env(Inner, inner.*, allocator, ptr, val);
        },
        .slice => unreachable,
        .string => ptr.* = val,
        .string_enum => ptr.* = std.meta.stringToEnum(T, val) orelse return "invalid enum variant",
    }
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

fn default_print_help(allocator: Allocator, w: *std.Io.Writer, ctx: HelpContext) !void {
    _ = allocator;
    const heading = ctx.heading_style;
    const heading_end = ctx.heading_style_end;
    try w.print("{s}USAGE{s}\n", .{ heading, heading_end });
    try w.flush();
}

fn exit_error(app_name: []const u8, message: []const u8) noreturn {
    std.debug.print("\x1b[31mERROR: {s}: {s}\x1b[0m\n", .{ app_name, message });
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

fn get_default_text(comptime kind: ValueKind, comptime field: std.builtin.Type.StructField) ?[]const u8 {
    // NOTE(tav): We bail on any .interface kinds.
    return switch (kind) {
        .bool => if (field.defaultValue().?) "true" else "false",
        .float => std.fmt.comptimePrint("{}", .{field.defaultValue().?}),
        .int => std.fmt.comptimePrint("{d}", .{field.defaultValue().?}),
        .interface => null,
        .optional => |inner| if (field.defaultValue().? == null) "null" else switch (inner.*) {
            .bool => if (field.defaultValue().?.? == true) "true" else "false",
            .float => std.fmt.comptimePrint("{}", .{field.defaultValue().?.?}),
            .int => std.fmt.comptimePrint("{d}", .{field.defaultValue().?.?}),
            .interface => null,
            .slice => unreachable,
            .string => std.fmt.comptimePrint("{s}", .{field.defaultValue().?.?}),
            .string_enum => @tagName(field.defaultValue().?.?),
        },
        .slice => |elem_kind| {
            return comptime blk: {
                var out: []const u8 = "[";
                for (field.defaultValue().?, 0..) |elem, i| {
                    if (i > 0) {
                        out = out ++ ", ";
                    }
                    out = out ++ switch (elem_kind.*) {
                        .bool => unreachable,
                        .float => std.fmt.comptimePrint("{}", .{elem}),
                        .int => std.fmt.comptimePrint("{d}", .{elem}),
                        .interface => return null,
                        .optional => unreachable,
                        .slice => unreachable,
                        .string => std.fmt.comptimePrint("{s}", .{elem}),
                        .string_enum => @tagName(elem),
                    };
                }
                break :blk out ++ "]";
            };
        },
        .string => std.fmt.comptimePrint("{s}", .{field.defaultValue().?}),
        .string_enum => @tagName(field.defaultValue().?),
    };
}

fn get_root_field_ptr(comptime RootCommand: type, comptime T: type, root: *RootCommand, comptime path: []const []const u8) *T {
    var ptr: *anyopaque = root;
    inline for (path, 0..) |elem, i| {
        const Field = comptime get_root_field_type(RootCommand, path[0..i]);
        const parent: *Field = @ptrCast(@alignCast(ptr));
        ptr = @ptrCast(&@field(parent, elem));
    }
    return @ptrCast(@alignCast(ptr));
}

fn get_root_field_type(comptime T: type, comptime path: []const []const u8) type {
    var typ = T;
    inline for (path) |elem| {
        typ = @TypeOf(@field(@as(typ, undefined), elem));
    }
    return typ;
}

fn kebab_to_screaming_snake(allocator: Allocator, ident: []const u8) ![]const u8 {
    var buf = try allocator.alloc(u8, ident.len);
    for (ident, 0..) |c, i| {
        if (c == '-') {
            buf[i] = '_';
        } else {
            buf[i] = std.ascii.toUpper(c);
        }
    }
    return buf;
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

fn needs_cli_text(kind: ValueKind) bool {
    return switch (kind) {
        .interface => true,
        .optional => |inner| switch (inner.*) {
            .interface => true,
            else => false,
        },
        .slice => |inner| switch (inner.*) {
            .interface => true,
            else => false,
        },
        else => false,
    };
}

fn needs_default_text(kind: ValueKind, root_show_defaults: ?bool, opt_show_default: ?bool) bool {
    if (!needs_cli_text(kind)) {
        return false;
    }
    if (opt_show_default == false) {
        return false;
    }
    return root_show_defaults == true;
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

fn print_deprecations(allocator: Allocator, io: std.Io, app_name: []const u8, deprecations: []const Deprecation, print_deprecations_func: *const fn (Allocator, *std.Io.Writer, []const u8, []const Deprecation) anyerror!void) void {
    var buf: [64]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buf);
    const w = &stderr.interface;
    print_deprecations_func(allocator, w, app_name, deprecations) catch {};
}

fn print_error(allocator: Allocator, io: std.Io, app_name: []const u8, err: ErrorResult, print_error_func: *const fn (Allocator, *std.Io.Writer, app_name: []const u8, ErrorResult) anyerror!void) void {
    var buf: [64]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buf);
    const w = &stderr.interface;
    print_error_func(allocator, w, app_name, err) catch {};
}

fn snake_to_kebab(comptime ident: []const u8) []const u8 {
    comptime {
        var buf = ident[0..ident.len].*;
        std.mem.replaceScalar(u8, &buf, '_', '-');
        const result = buf;
        return &result;
    }
}

fn supports_cli_text(comptime T: type, comptime kind: ValueKind) bool {
    return switch (kind) {
        .interface => @hasDecl(T, "cli_text"),
        .optional => |inner| supports_cli_text(@typeInfo(T).optional.child, inner.*),
        .slice => |inner| supports_cli_text(@typeInfo(T).pointer.child, inner.*),
        else => false,
    };
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

const Duration = struct {
    value: i64,

    pub fn cli_text2(self: Duration, allocator: Allocator) ![]const u8 {
        _ = self;
        return try std.fmt.allocPrint(allocator, "1h1m1s", .{});
    }

    pub fn decode_cli_arg(allocator: Allocator, raw: []const u8) DecodeResult(Duration) {
        _ = allocator;
        _ = raw;
        return .{ .ok = Duration{ .value = 1 } };
    }
};

const MyApp = struct {
    Foo: struct {
        meow: []const i64 = &.{ 1, 2, 3 },
        Bar: struct {
            hello: bool = false,
        },
        baz: Duration,
    },
    Boom: struct {
        hmz: i64,
    },
    spam: bool,
};

pub fn main(init: std.process.Init) !void {
    var app = App(MyApp).init(.{
        .name = "kickass",
        .show_defaults = true,
    });

    app.subcommand(.Foo, .{
        .summary = "Foo command",
        .name = "fx",
        // .supports_positional_args = false,
        // .max_args = 1,
    });
    // app.option(.Foo_baz, .{ .summary = "option" });
    app.subcommand(.Foo_Bar, .{
        .summary = "Foo Bar command",
    });
    app.subcommand(.Boom, .{
        .summary = "Boom command",
        // .name = "fx",
    });
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
        .Boom => {
            std.debug.print("Boom\n", .{});
        },
    }
}
