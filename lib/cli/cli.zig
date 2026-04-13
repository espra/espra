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
        global_epilog: ?[]const u8 = null,
        global_prolog: ?[]const u8 = null,
        help_style: HelpStyle = .{},
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

    const ResolvedResult = union(enum) {
        ok: Resolved(RootCommand, SubcommandGroup, OptionGroup),
        err: ValidationError,
    };

    const Alias = struct {
        aliases: []const []const u8,
        subcommand: *ResolvedCommand(RootCommand, SubcommandGroup, OptionGroup),
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

        pub fn exit(self: *Self, allocator: Allocator, io: std.Io, message: []const u8) noreturn {
            print_error(allocator, io, self.app_options.name, .{ .raw = message }, self.app_options.print_error orelse default_print_error);
            std.process.exit(1);
        }

        pub fn exitf(self: *Self, allocator: Allocator, io: std.Io, comptime format: []const u8, args: anytype) noreturn {
            const message = std.fmt.allocPrint(allocator, format, args) catch oom(self.app_options.name);
            self.exit(allocator, io, message);
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
            try self.print_help_to(allocator, io, w, cmd);
        }

        pub fn print_help_to(self: *Self, allocator: Allocator, io: std.Io, w: *std.Io.Writer, cmd: InvokedCommand(RootCommand)) !void {
            var arena: std.heap.ArenaAllocator = .init(allocator);
            const alloc = arena.allocator();
            defer arena.deinit();
            const resolved = switch (self.resolve_definitions(alloc)) {
                .ok => |r| r,
                .err => |e| {
                    const err: ErrorResult = .{ .validation = e };
                    print_error(alloc, io, self.app_options.name, err, self.app_options.print_error orelse default_print_error);
                    std.process.exit(1);
                },
            };
            const ctx = self.build_help_context(alloc, cmd, resolved);
            if (self.app_options.print_help) |print| {
                try print(alloc, w, ctx);
            } else {
                try default_print_help(alloc, w, ctx);
            }
        }

        pub fn require_explicit_definitions(self: *Self) void {
            self.require_explicit = true;
        }

        pub fn subcommand(self: *Self, cmd: Subcommand(RootCommand), info: SubcommandInfo(RootCommand, SubcommandGroup)) void {
            self.subcommands[@intFromEnum(cmd)] = info;
        }

        fn build_help_context(self: *Self, allocator: Allocator, invoked: InvokedCommand(RootCommand), resolved: Resolved(RootCommand, SubcommandGroup, OptionGroup)) HelpContext {
            const id = @intFromEnum(invoked);
            const cmd = get_command(resolved, id);

            // Compute the command path.
            var path: std.ArrayList([]const u8) = .empty;
            var cur: ?*ResolvedCommand(RootCommand, SubcommandGroup, OptionGroup) = cmd;
            while (cur) |c| {
                if (c == resolved.root) {
                    break;
                }
                path.append(allocator, c.name) catch oom(self.app_options.name);
                cur = get_command(resolved, c.parent_command);
            }
            std.mem.reverse([]const u8, path.items);
            const command_path = std.mem.join(allocator, " ", path.items) catch oom(self.app_options.name);
            const app_name_with_subcommands = if (command_path.len > 0)
                std.fmt.allocPrint(allocator, "{s} {s}", .{ self.app_options.name, command_path }) catch oom(self.app_options.name)
            else
                self.app_options.name;

            // Compute and group subcommands.
            var has_subcommands = false;
            var max_subcommand_width: usize = 0;
            var ungrouped_subcmds: std.ArrayList(SubcommandHelpEntry) = .empty;
            var grouped_subcmds: std.ArrayList(GroupBucket(SubcommandHelpEntry)) = .empty;
            var subcmd_it = cmd.subcommands.valueIterator();
            while (subcmd_it.next()) |subcmd_ptr| {
                const subcmd = subcmd_ptr.*;
                if (subcmd.hidden or subcmd.is_alias or subcmd.is_stub) {
                    continue;
                }
                has_subcommands = true;
                const entry = SubcommandHelpEntry{
                    .deprecated = subcmd.deprecated,
                    .name = subcmd.name,
                    .summary = subcmd.summary,
                };
                max_subcommand_width = @max(max_subcommand_width, subcmd.name.len);
                if (SubcommandGroup != void) {
                    if (subcmd.group) |group| {
                        const name = allocator.dupe(u8, @tagName(group)) catch oom(self.app_options.name);
                        std.mem.replaceScalar(u8, name, '_', ' ');
                        const order = @intFromEnum(group);
                        for (grouped_subcmds.items) |*bucket| {
                            if (std.mem.eql(u8, bucket.name, name)) {
                                bucket.items.append(allocator, entry) catch oom(self.app_options.name);
                                break;
                            }
                        } else {
                            var bucket = GroupBucket(SubcommandHelpEntry){
                                .items = .empty,
                                .name = name,
                                .order = order,
                            };
                            bucket.items.append(allocator, entry) catch oom(self.app_options.name);
                            grouped_subcmds.append(allocator, bucket) catch oom(self.app_options.name);
                        }
                        continue;
                    }
                }
                ungrouped_subcmds.append(allocator, entry) catch oom(self.app_options.name);
            }
            std.mem.sort(GroupBucket(SubcommandHelpEntry), grouped_subcmds.items, {}, struct {
                fn lt(_: void, a: GroupBucket(SubcommandHelpEntry), b: GroupBucket(SubcommandHelpEntry)) bool {
                    return a.order < b.order;
                }
            }.lt);
            const sort_subcmd = struct {
                fn lt(_: void, a: SubcommandHelpEntry, b: SubcommandHelpEntry) bool {
                    return std.mem.order(u8, a.name, b.name) == .lt;
                }
            }.lt;
            var subcommand_groups: std.ArrayList(Group(SubcommandHelpEntry)) = .empty;
            if (ungrouped_subcmds.items.len > 0) {
                std.mem.sort(SubcommandHelpEntry, ungrouped_subcmds.items, {}, sort_subcmd);
                subcommand_groups.append(allocator, .{
                    .items = ungrouped_subcmds.items,
                    .name = "Commands",
                }) catch oom(self.app_options.name);
            }
            for (grouped_subcmds.items) |group| {
                std.mem.sort(SubcommandHelpEntry, group.items.items, {}, sort_subcmd);
                subcommand_groups.append(allocator, .{
                    .items = group.items.items,
                    .name = group.name,
                }) catch oom(self.app_options.name);
            }

            // Compute and group options.
            var has_options = false;
            var has_global_options = false;
            var has_non_global_options = false;
            var max_option_width: usize = 0;
            var max_value_label_width: usize = 0;
            var ungrouped_opts: std.ArrayList(OptionHelpEntry) = .empty;
            var global_opts: std.ArrayList(OptionHelpEntry) = .empty;
            var grouped_opts: std.ArrayList(GroupBucket(OptionHelpEntry)) = .empty;
            ungrouped_opts.append(allocator, OptionHelpEntry{
                .long = "help",
                .short = 'h',
                .summary = "Show help and exit",
            }) catch oom(self.app_options.name);
            var opt_it = cmd.long_flags.valueIterator();
            while (opt_it.next()) |opt_ptr| {
                const opt = opt_ptr.*;
                if (opt.hidden or opt.is_alias) {
                    continue;
                }
                has_options = true;
                const short = if (self.options[opt.id]) |info| info.short else null;
                const entry = OptionHelpEntry{
                    .default_text = opt.default_text,
                    .deprecated = opt.deprecated,
                    .long = opt.long,
                    .required = opt.required,
                    .short = short,
                    .summary = opt.summary,
                    .value_label = opt.value_label orelse opt.kind.value_label(allocator, self.app_options.name),
                };
                max_value_label_width = @max(max_value_label_width, entry.value_label.len);
                max_option_width = @max(max_option_width, opt.long.len);
                if (opt.inherited) {
                    global_opts.append(allocator, entry) catch oom(self.app_options.name);
                    has_global_options = true;
                    continue;
                } else {
                    has_non_global_options = true;
                }
                if (OptionGroup != void) {
                    if (opt.group) |group| {
                        const name = allocator.dupe(u8, @tagName(group)) catch oom(self.app_options.name);
                        std.mem.replaceScalar(u8, name, '_', ' ');
                        const order = @intFromEnum(group);
                        for (grouped_opts.items) |*bucket| {
                            if (std.mem.eql(u8, bucket.name, name)) {
                                bucket.items.append(allocator, entry) catch oom(self.app_options.name);
                                break;
                            }
                        } else {
                            var bucket = GroupBucket(OptionHelpEntry){
                                .items = .empty,
                                .name = name,
                                .order = order,
                            };
                            bucket.items.append(allocator, entry) catch oom(self.app_options.name);
                            grouped_opts.append(allocator, bucket) catch oom(self.app_options.name);
                        }
                        continue;
                    }
                }
                ungrouped_opts.append(allocator, entry) catch oom(self.app_options.name);
            }
            std.mem.sort(GroupBucket(OptionHelpEntry), grouped_opts.items, {}, struct {
                fn lt(_: void, a: GroupBucket(OptionHelpEntry), b: GroupBucket(OptionHelpEntry)) bool {
                    return a.order < b.order;
                }
            }.lt);
            const sort_opt = struct {
                fn lt(_: void, a: OptionHelpEntry, b: OptionHelpEntry) bool {
                    return std.mem.order(u8, a.long, b.long) == .lt;
                }
            }.lt;
            var option_groups: std.ArrayList(Group(OptionHelpEntry)) = .empty;
            if (ungrouped_opts.items.len > 0) {
                std.mem.sort(OptionHelpEntry, ungrouped_opts.items, {}, sort_opt);
                option_groups.append(allocator, .{
                    .items = ungrouped_opts.items,
                    .name = "Options",
                }) catch oom(self.app_options.name);
            }
            if (global_opts.items.len > 0) {
                std.mem.sort(OptionHelpEntry, global_opts.items, {}, sort_opt);
                option_groups.append(allocator, .{
                    .items = global_opts.items,
                    .name = "Global Options",
                }) catch oom(self.app_options.name);
            }
            for (grouped_opts.items) |group| {
                std.mem.sort(OptionHelpEntry, group.items.items, {}, sort_opt);
                option_groups.append(allocator, .{
                    .items = group.items.items,
                    .name = group.name,
                }) catch oom(self.app_options.name);
            }

            // Normalize the usage text.
            const commands_part: []const u8 = if (has_global_options) " [options] <command>" else " <command>";
            const options_part: []const u8 = if (has_options) " [options]" else "";
            var usage: ?[]const []const u8 = if (cmd.usage) |cmd_usage| switch (cmd_usage) {
                .full_text => |text| blk: {
                    if (text.len == 0) {
                        break :blk null;
                    }
                    const lines = allocator.alloc([]const u8, 1) catch oom(self.app_options.name);
                    lines[0] = text;
                    break :blk lines;
                },
                .positional_args => |pos| blk: {
                    if (pos.len == 0) {
                        break :blk null;
                    }
                    const extra: usize = if (has_subcommands) 1 else 0;
                    const lines = allocator.alloc([]const u8, 1 + extra) catch oom(self.app_options.name);
                    if (has_subcommands) {
                        lines[0] = std.fmt.allocPrint(allocator, "{s}{s}", .{ app_name_with_subcommands, commands_part }) catch oom(self.app_options.name);
                    }
                    lines[0 + extra] = std.fmt.allocPrint(allocator, "{s}{s} {s}", .{ app_name_with_subcommands, options_part, pos }) catch oom(self.app_options.name);
                    break :blk lines;
                },
                .positional_args_multi => |multi| blk: {
                    if (multi.len == 0) {
                        break :blk null;
                    }
                    var count: usize = 0;
                    for (multi) |pos| {
                        if (pos.len == 0) {
                            continue;
                        }
                        count += 1;
                    }
                    if (count == 0) {
                        break :blk null;
                    }
                    count += if (has_subcommands) 1 else 0;
                    const lines = allocator.alloc([]const u8, count) catch oom(self.app_options.name);
                    var idx: usize = 0;
                    if (has_subcommands) {
                        lines[0] = std.fmt.allocPrint(allocator, "{s}{s}", .{ app_name_with_subcommands, commands_part }) catch oom(self.app_options.name);
                        idx = 1;
                    }
                    for (multi) |pos| {
                        if (pos.len == 0) {
                            continue;
                        }
                        lines[idx] = std.fmt.allocPrint(allocator, "{s}{s} {s}", .{ app_name_with_subcommands, options_part, pos }) catch oom(self.app_options.name);
                        idx += 1;
                    }
                    break :blk lines;
                },
            } else null;

            if (usage == null) {
                var lines_list: std.ArrayList([]const u8) = .empty;
                if (has_subcommands) {
                    lines_list.append(allocator, std.fmt.allocPrint(allocator, "{s}{s}", .{ app_name_with_subcommands, commands_part }) catch oom(self.app_options.name)) catch oom(self.app_options.name);
                }
                if (cmd.supports_positional_args == true) {
                    lines_list.append(allocator, std.fmt.allocPrint(allocator, "{s}{s} [args...]", .{ app_name_with_subcommands, options_part }) catch oom(self.app_options.name)) catch oom(self.app_options.name);
                } else if (!has_subcommands or has_non_global_options) {
                    lines_list.append(allocator, std.fmt.allocPrint(allocator, "{s}{s}", .{ app_name_with_subcommands, options_part }) catch oom(self.app_options.name)) catch oom(self.app_options.name);
                }
                usage = lines_list.items;
            }

            return .{
                .app_name = self.app_options.name,
                .app_name_with_subcommands = app_name_with_subcommands,
                .command = .{
                    .description = cmd.description,
                    .epilog = cmd.epilog,
                    .prolog = cmd.prolog,
                    .summary = cmd.summary,
                    .usage = usage,
                },
                .command_path = command_path,
                .has_options = has_options,
                .has_subcommands = has_subcommands,
                .max_option_width = max_option_width + max_value_label_width + 1,
                .max_subcommand_width = max_subcommand_width,
                .option_groups = option_groups.items,
                .subcommand_groups = subcommand_groups.items,
                .style = self.app_options.help_style,
                .terminal_width = 80,
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

        fn copy_inherited_options(self: *Self, comptime field_name: []const u8, comptime fmt: []const u8, allocator: Allocator, source: *ResolvedCommand(RootCommand, SubcommandGroup, OptionGroup), target: *ResolvedCommand(RootCommand, SubcommandGroup, OptionGroup)) ?ValidationError {
            var it = @field(source, field_name).iterator();
            while (it.next()) |entry| {
                if (!entry.value_ptr.*.inherited) {
                    continue;
                }
                if (@field(target, field_name).get(entry.key_ptr.*)) |existing| {
                    if (existing.id != entry.value_ptr.*.id) {
                        return .{
                            .option = .{
                                .message = std.fmt.allocPrint(allocator, "shadows inherited option {s}: " ++ fmt, .{ entry.value_ptr.*.dotted_path, entry.key_ptr.* }) catch oom(self.app_options.name),
                                .option_name = existing.dotted_path,
                            },
                        };
                    }
                    continue;
                }
                @field(target, field_name).put(allocator, entry.key_ptr.*, entry.value_ptr.*) catch oom(self.app_options.name);
            }
            return null;
        }

        fn propagate_inherited_options(self: *Self, allocator: Allocator, cmd: *ResolvedCommand(RootCommand, SubcommandGroup, OptionGroup)) ?ValidationError {
            var subcommands = cmd.subcommands.valueIterator();
            while (subcommands.next()) |subcmd_ptr| {
                const subcmd = subcmd_ptr.*;
                if (subcmd.is_stub or subcmd.is_alias) {
                    continue;
                }
                if (self.copy_inherited_options("long_flags", "\"--{s}\"", allocator, cmd, subcmd)) |err| return err;
                if (self.copy_inherited_options("short_flags", "\"-{c}\"", allocator, cmd, subcmd)) |err| return err;
                for (subcmd.aliases) |alias| {
                    if (self.copy_inherited_options("long_flags", "\"--{s}\"", allocator, subcmd, alias)) |err| return err;
                    if (self.copy_inherited_options("short_flags", "\"-{c}\"", allocator, subcmd, alias)) |err| return err;
                }
                if (self.propagate_inherited_options(allocator, subcmd)) |err| {
                    return err;
                }
            }
            return null;
        }

        fn register_builtin_subcommand(self: *Self, allocator: Allocator, root: *ResolvedCommand(RootCommand, SubcommandGroup, OptionGroup), action: BuiltinAction, name: []const u8, summary: []const u8) ?ValidationError {
            const cmd = allocator.create(ResolvedCommand(RootCommand, SubcommandGroup, OptionGroup)) catch oom(self.app_options.name);
            cmd.* = .{
                .action = action,
                .dotted_path = name,
                .epilog = self.app_options.global_epilog,
                .id = 0,
                .is_stub = true,
                .name = name,
                .prolog = self.app_options.global_prolog,
                .summary = summary,
                .supports_positional_args = false,
            };
            if (root.subcommands.get(name)) |existing| {
                return .{
                    .subcommand = .{
                        .message = std.fmt.allocPrint(allocator, "conflicts with auto-generated {s} subcommand", .{name}) catch oom(self.app_options.name),
                        .subcommand_name = existing.dotted_path,
                    },
                };
            }
            root.subcommands.put(allocator, name, cmd) catch oom(self.app_options.name);
            return null;
        }

        fn register_negated_option(self: *Self, allocator: Allocator, cmd: *ResolvedCommand(RootCommand, SubcommandGroup, OptionGroup), opt: *ResolvedOption(RootCommand, OptionGroup), flag: []const u8, comptime label: []const u8) ?ValidationError {
            const clone = allocator.create(ResolvedOption(RootCommand, OptionGroup)) catch oom(self.app_options.name);
            clone.* = opt.*;
            clone.hidden = true;
            clone.long = std.fmt.allocPrint(allocator, "no-{s}", .{flag}) catch oom(self.app_options.name);
            clone.negated = true;
            if (cmd.long_flags.get(clone.long)) |existing| {
                const existing_status = if (existing.is_alias)
                    "alias"
                else
                    "definition";
                return .{
                    .option = .{
                        .message = std.fmt.allocPrint(allocator, "negated " ++ label ++ " conflicts with existing {s} for {s}: \"{s}\"", .{ existing_status, existing.dotted_path, clone.long }) catch oom(self.app_options.name),
                        .option_name = opt.dotted_path,
                    },
                };
            }
            cmd.long_flags.put(allocator, clone.long, clone) catch oom(self.app_options.name);
            return null;
        }

        fn resolve_definitions(self: *Self, allocator: Allocator) ResolvedResult {
            const root = allocator.create(ResolvedCommand(RootCommand, SubcommandGroup, OptionGroup)) catch oom(self.app_options.name);
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
            if (self.app_options.global_epilog != null and root.epilog == null) {
                root.epilog = self.app_options.global_epilog;
            }
            if (self.app_options.global_prolog != null and root.prolog == null) {
                root.prolog = self.app_options.global_prolog;
            }
            var aliased: std.ArrayList(Alias) = .empty;
            var resolved = Resolved(RootCommand, SubcommandGroup, OptionGroup){
                .options = .{undefined} ** options_count,
                .root = root,
                .subcommands = .{undefined} ** subcommands_count,
            };

            // Resolve subcommands.
            if (subcommands_count > 0) {
                for (self.subcommands, self.subcommand_meta, 0..) |s, meta, i| {
                    const info = s orelse SubcommandInfo(RootCommand, SubcommandGroup){};
                    const cmd = allocator.create(ResolvedCommand(RootCommand, SubcommandGroup, OptionGroup)) catch oom(self.app_options.name);
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
                        .parent_command = meta.parent_command,
                        .preserve_unmatched_short_options = info.preserve_unmatched_short_options,
                        .prolog = info.prolog,
                        .summary = info.summary,
                        .supports_positional_args = info.supports_positional_args,
                        .usage = info.usage,
                    };
                    if (self.app_options.global_epilog != null and cmd.epilog == null) {
                        cmd.epilog = self.app_options.global_epilog;
                    }
                    if (self.app_options.global_prolog != null and cmd.prolog == null) {
                        cmd.prolog = self.app_options.global_prolog;
                    }
                    const parent = get_command(resolved, cmd.parent_command);
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
            }

            // Resolve options.
            for (self.options, self.option_meta, 0..) |o, meta, i| {
                const info = o orelse OptionInfo(RootCommand, OptionGroup){};
                const opt = allocator.create(ResolvedOption(RootCommand, OptionGroup)) catch oom(self.app_options.name);
                opt.* = .{
                    .complete = info.complete,
                    .decode = meta.decode,
                    .deprecated = info.deprecated,
                    .dotted_path = meta.dotted_path,
                    .group = info.group,
                    .hidden = info.hidden,
                    .id = i,
                    .inherited = info.inherited,
                    .kind = meta.kind,
                    .long = info.long orelse meta.long,
                    .parent_command = meta.parent_command,
                    .summary = info.summary,
                    .validate = info.validate,
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
                if (!meta.has_default) {
                    if (info.required != null and info.required.? == false) {
                        return .{
                            .err = .{
                                .option = .{
                                    .message = "`required` is set to false but field has no default value",
                                    .option_name = opt.dotted_path,
                                },
                            },
                        };
                    }
                    switch (opt.kind) {
                        .bool, .slice => {},
                        else => opt.required = true,
                    }
                } else if (info.required != null and info.required.? == true) {
                    opt.required = true;
                }
                if (info.show_default != false and (self.app_options.show_defaults == true or info.show_default == true)) {
                    if (opt.kind == .bool) {
                        if (info.show_default == true) {
                            if (info.default_text) |text| {
                                opt.default_text = text;
                            } else if (meta.default_text) |text| {
                                opt.default_text = text;
                            } else {
                                opt.default_text = "false";
                            }
                        }
                    } else if (opt.kind == .slice and !meta.has_default) {
                        if (info.show_default == true) {
                            if (info.default_text) |text| {
                                opt.default_text = text;
                            } else {
                                opt.default_text = "[]";
                            }
                        }
                    } else if (meta.has_default) {
                        if (info.default_text) |text| {
                            opt.default_text = text;
                        } else if (meta.default_text) |text| {
                            opt.default_text = text;
                        } else if (!meta.format_cli) {
                            return .{
                                .err = .{
                                    .option = .{
                                        .message = "missing default text for custom data type without a `format_cli` method",
                                        .option_name = meta.dotted_path,
                                    },
                                },
                            };
                        }
                    }
                    if (opt.default_text != null and opt.default_text.?.len == 0) {
                        opt.default_text = "\"\"";
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
                const cmd = get_command(resolved, opt.parent_command);
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
                    if (short == 'h') {
                        return .{
                            .err = .{
                                .option = .{
                                    .message = "`short` value conflicts with the built-in \"-h\" flag",
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
                const this_status = if (info.long == null)
                    "inferred "
                else
                    "";
                if (self.validate_long_flag(allocator, cmd, opt.long, opt, "`long`", this_status)) |err| {
                    return .{ .err = err };
                }
                cmd.long_flags.put(allocator, opt.long, opt) catch oom(self.app_options.name);
                var negatable = false;
                if (opt.kind == .bool) {
                    if (info.negatable == null) {
                        negatable = meta.has_default and std.mem.eql(u8, meta.default_text.?, "true");
                    } else {
                        negatable = info.negatable.?;
                    }
                } else if (info.negatable != null) {
                    return .{
                        .err = .{
                            .option = .{
                                .message = "`negatable` is only valid for bool options",
                                .option_name = opt.dotted_path,
                            },
                        },
                    };
                }
                if (negatable) {
                    if (self.register_negated_option(allocator, cmd, opt, opt.long, "`long` option")) |err| {
                        return .{ .err = err };
                    }
                }
                for (info.long_aliases) |alias| {
                    if (self.validate_long_flag(allocator, cmd, alias, opt, "`long_alias` value", "")) |err| {
                        return .{ .err = err };
                    }
                    const clone = allocator.create(ResolvedOption(RootCommand, OptionGroup)) catch oom(self.app_options.name);
                    clone.* = opt.*;
                    clone.hidden = true;
                    clone.is_alias = true;
                    cmd.long_flags.put(allocator, alias, clone) catch oom(self.app_options.name);
                    if (negatable) {
                        if (self.register_negated_option(allocator, cmd, opt, alias, "`long_alias` value")) |err| {
                            return .{ .err = err };
                        }
                    }
                }
                resolved.options[i] = opt;
            }

            // Validate option dependencies.
            for (resolved.options) |opt| {
                if (self.validate_option_relations(allocator, resolved, opt, "depends on", opt.depends_on)) |err| {
                    return .{ .err = err };
                }
                if (self.validate_option_relations(allocator, resolved, opt, "mutually exclusive with", opt.mutually_exclusive_with)) |err| {
                    return .{ .err = err };
                }
            }

            // Define subcommand aliases.
            if (subcommands_count > 0) {
                for (aliased.items) |a| {
                    var aliases: std.ArrayList(*ResolvedCommand(RootCommand, SubcommandGroup, OptionGroup)) = .empty;
                    for (a.aliases) |alias| {
                        const clone = allocator.create(ResolvedCommand(RootCommand, SubcommandGroup, OptionGroup)) catch oom(self.app_options.name);
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
                                    const child = allocator.create(ResolvedCommand(RootCommand, SubcommandGroup, OptionGroup)) catch oom(self.app_options.name);
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
                    a.subcommand.aliases = aliases.toOwnedSlice(allocator) catch oom(self.app_options.name);
                }
            }

            // Define built-in subcommands.
            if (self.app_options.enable_completion_command) {
                if (self.register_builtin_subcommand(allocator, root, .completion, "completion", "Generate shell completion script")) |err| {
                    return .{ .err = err };
                }
            }
            if (self.app_options.enable_help_command) {
                if (self.register_builtin_subcommand(allocator, root, .help, "help", "Show help and exit")) |err| {
                    return .{ .err = err };
                }
            }
            if (self.app_options.version != null) {
                if (self.register_builtin_subcommand(allocator, root, .version, "version", "Show version and exit")) |err| {
                    return .{ .err = err };
                }
            }

            if (self.propagate_inherited_options(allocator, root)) |err| {
                return .{ .err = err };
            }
            resolve_subcommands_only(root);
            return .{ .ok = resolved };
        }

        fn run_completion(self: *Self, shell: []const u8) void {
            _ = self;
            _ = shell;
        }

        fn validate_long_flag(self: *Self, allocator: Allocator, cmd: *ResolvedCommand(RootCommand, SubcommandGroup, OptionGroup), flag: []const u8, opt: *ResolvedOption(RootCommand, OptionGroup), comptime label: []const u8, prefix: []const u8) ?ValidationError {
            if (flag.len == 0) {
                return .{
                    .option = .{
                        .message = label ++ " is an empty string",
                        .option_name = opt.dotted_path,
                    },
                };
            }
            if (flag[0] == '-') {
                return .{
                    .option = .{
                        .message = label ++ " starts with a hyphen",
                        .option_name = opt.dotted_path,
                    },
                };
            }
            if (std.mem.eql(u8, flag, "help")) {
                return .{
                    .option = .{
                        .message = label ++ " conflicts with the built-in \"--help\" flag",
                        .option_name = opt.dotted_path,
                    },
                };
            }
            if (flag.len == 1) {
                return .{
                    .option = .{
                        .message = std.fmt.allocPrint(allocator, "{s}" ++ label ++ " is a single character", .{prefix}) catch oom(self.app_options.name),
                        .option_name = opt.dotted_path,
                    },
                };
            }
            if (is_invalid_long_flag(flag)) |char| {
                return .{
                    .option = .{
                        .message = std.fmt.allocPrint(allocator, "{s}" ++ label ++ " contains an invalid character: \"{c}\" (0x{x:0>2})", .{ prefix, char, char }) catch oom(self.app_options.name),
                        .option_name = opt.dotted_path,
                    },
                };
            }
            if (cmd.long_flags.get(flag)) |existing| {
                const existing_status = if (existing.is_alias)
                    "alias"
                else
                    "definition";
                return .{
                    .option = .{
                        .message = std.fmt.allocPrint(allocator, "{s}" ++ label ++ " conflicts with existing {s} for {s}: \"{s}\"", .{ prefix, existing_status, existing.dotted_path, flag }) catch oom(self.app_options.name),
                        .option_name = opt.dotted_path,
                    },
                };
            }
            return null;
        }

        fn validate_option_relations(self: *Self, allocator: Allocator, resolved: Resolved(RootCommand, SubcommandGroup, OptionGroup), opt: *ResolvedOption(RootCommand, OptionGroup), comptime relation: []const u8, related_ids: []const usize) ?ValidationError {
            for (related_ids) |dep| {
                if (dep == opt.id) {
                    return .{
                        .option = .{
                            .message = "option " ++ relation ++ " itself",
                            .option_name = opt.dotted_path,
                        },
                    };
                }
                const dep_opt = resolved.options[dep];
                if (dep_opt.parent_command == opt.parent_command) {
                    continue;
                }
                if (!dep_opt.inherited) {
                    return .{
                        .option = .{
                            .message = std.fmt.allocPrint(allocator, relation ++ " an option that's not inherited: {s}", .{dep_opt.dotted_path}) catch oom(self.app_options.name),
                            .option_name = opt.dotted_path,
                        },
                    };
                }
                var cmd: ?*ResolvedCommand(RootCommand, SubcommandGroup, OptionGroup) = get_command(resolved, opt.parent_command);
                while (cmd) |c| {
                    if (dep_opt.parent_command == c.id) {
                        break;
                    }
                    if (c == resolved.root) {
                        return .{
                            .option = .{
                                .message = std.fmt.allocPrint(allocator, relation ++ " an option that's not in its command hierarchy: {s}", .{dep_opt.dotted_path}) catch oom(self.app_options.name),
                                .option_name = opt.dotted_path,
                            },
                        };
                    }
                    cmd = get_command(resolved, c.parent_command);
                }
            }
            return null;
        }

        fn get_command(resolved: Resolved(RootCommand, SubcommandGroup, OptionGroup), id: usize) *ResolvedCommand(RootCommand, SubcommandGroup, OptionGroup) {
            if (id == 0) {
                return resolved.root;
            }
            if (subcommands_count == 0) unreachable;
            return resolved.subcommands[id - 1];
        }

        fn resolve_subcommands_only(cmd: *ResolvedCommand(RootCommand, SubcommandGroup, OptionGroup)) void {
            if (cmd.subcommands.count() > 0) {
                if (cmd.supports_positional_args != true) {
                    cmd.supports_positional_args = false;
                    cmd.subcommands_only = true;
                    for (cmd.aliases) |alias| {
                        alias.supports_positional_args = false;
                        alias.subcommands_only = true;
                    }
                }
            }
            var subcommands = cmd.subcommands.valueIterator();
            while (subcommands.next()) |subcmd_ptr| {
                resolve_subcommands_only(subcmd_ptr.*);
            }
        }
    };
}

pub const BuiltinAction = enum {
    none,
    completion,
    help,
    version,
};

pub const CommandError = struct {
    command_path: []const u8,
    kind: Kind,

    pub const Kind = union(enum) {
        too_few_args: struct { min_args: usize, usage: []const u8 },
        too_many_args: struct { max_args: usize, usage: []const u8 },
        unknown_subcommand: struct { subcommand_name: []const u8, suggestions: []const []const u8 },
    };
};

pub const CommandHelpEntry = struct {
    description: ?[]const u8 = null,
    epilog: ?[]const u8 = null,
    prolog: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    usage: ?[]const []const u8 = null,
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
    raw: []const u8,
    validation: ValidationError,
};

pub fn Group(comptime T: type) type {
    return struct {
        items: []const T,
        name: []const u8,
    };
}

pub const HelpContext = struct {
    app_name: []const u8,
    app_name_with_subcommands: []const u8,
    command: CommandHelpEntry,
    command_path: []const u8,
    has_options: bool,
    has_subcommands: bool,
    max_option_width: usize,
    max_subcommand_width: usize,
    option_groups: []const Group(OptionHelpEntry),
    subcommand_groups: []const Group(SubcommandHelpEntry),
    style: HelpStyle,
    terminal_width: usize,
};

pub const HelpStyle = struct {
    deprecation: []const u8 = "\x1b[1;38;2;255;100;100m",
    deprecation_end: []const u8 = "\x1b[0m",
    heading: []const u8 = "\x1b[1;38;2;255;175;95m",
    heading_end: []const u8 = "\x1b[0m",
    highlight: []const u8 = "\x1b[1;38;2;100;200;255m",
    highlight_end: []const u8 = "\x1b[0m",
    indent: usize = 2,

    pub const dark = HelpStyle{};

    pub const light = HelpStyle{
        .deprecation = "\x1b[1;38;2;255;100;100m",
        .heading = "\x1b[1;38;2;180;100;20m",
        .highlight = "\x1b[1;38;2;25;120;180m",
    };

    pub const none = HelpStyle{
        .deprecation = "",
        .deprecation_end = "",
        .heading = "",
        .heading_end = "",
        .highlight = "",
        .highlight_end = "",
    };

    pub const plain = HelpStyle{
        .deprecation = "\x1b[31;1m",
        .heading = "\x1b[32;1m",
        .highlight = "\x1b[36;1m",
    };
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
        unknown_option: struct { suggestions: []const []const u8 },
        unmet_dependency: struct { related_option_name: []const u8 },
    };
};

pub const OptionHelpEntry = struct {
    default_text: ?[]const u8 = null,
    deprecated: ?[]const u8 = null,
    long: []const u8,
    required: bool = false,
    short: ?u8 = null,
    summary: ?[]const u8 = null,
    value_label: []const u8 = "",
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
        negatable: ?bool = null,
        required: ?bool = null,
        short: ?u8 = null,
        show_default: ?bool = null,
        summary: ?[]const u8 = null,
        validate: ?*const fn (Allocator, *RootCommand) ?[]const u8 = null,
        value_label: ?[]const u8 = null,
    };
}

pub fn ParseResult(comptime RootCommand: type) type {
    return union(enum) {
        err: ErrorResult,
        ok: SuccessResult(RootCommand),
    };
}

pub fn ResolvedOption(comptime RootCommand: type, comptime OptionGroup: type) type {
    return struct {
        complete: ?Completer(RootCommand) = null,
        decode: *const fn (Allocator, *RootCommand, DecodeSource) ?[]const u8,
        default_text: ?[]const u8 = null,
        depends_on: []const usize = &.{},
        deprecated: ?[]const u8 = null,
        dotted_path: []const u8,
        env_var: ?[]const u8 = null,
        group: ?OptionGroup = null,
        hidden: bool = false,
        id: usize,
        inherited: bool = false,
        is_alias: bool = false,
        kind: ValueKind,
        long: []const u8,
        mutually_exclusive_with: []const usize = &.{},
        negated: bool = false,
        parent_command: usize = 0,
        required: bool = false,
        summary: ?[]const u8 = null,
        validate: ?*const fn (Allocator, *RootCommand) ?[]const u8 = null,
        value_label: ?[]const u8 = null,
    };
}

pub fn ResolvedCommand(comptime RootCommand: type, comptime SubcommandGroup: type, comptime OptionGroup: type) type {
    return struct {
        const Self = @This();
        action: BuiltinAction = .none,
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
        long_flags: std.StringHashMapUnmanaged(*ResolvedOption(RootCommand, OptionGroup)) = .empty,
        max_args: ?usize = null,
        min_args: ?usize = null,
        name: []const u8,
        parent_command: usize = 0,
        preserve_unmatched_short_options: bool = false,
        prolog: ?[]const u8 = null,
        short_flags: std.AutoHashMapUnmanaged(u8, *ResolvedOption(RootCommand, OptionGroup)) = .empty,
        subcommands: std.StringHashMapUnmanaged(*Self) = .empty,
        subcommands_only: bool = false,
        summary: ?[]const u8 = null,
        supports_positional_args: ?bool = null,
        usage: ?Usage = null,
    };
}

pub fn Resolved(comptime RootCommand: type, comptime SubcommandGroup: type, comptime OptionGroup: type) type {
    return struct {
        options: [find_options(RootCommand, "")]*ResolvedOption(RootCommand, OptionGroup),
        root: *ResolvedCommand(RootCommand, SubcommandGroup, OptionGroup),
        subcommands: [find_subcommands(RootCommand, "")]*ResolvedCommand(RootCommand, SubcommandGroup, OptionGroup),
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
    full_text: []const u8,
    positional_args: []const u8,
    positional_args_multi: []const []const u8,
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
    indent: usize = 0,
    start_col: usize = 0,
    width: usize = 80,
};

fn GroupBucket(comptime T: type) type {
    return struct {
        items: std.ArrayList(T),
        name: []const u8,
        order: usize,
    };
}

fn OptionMeta(comptime RootCommand: type) type {
    return struct {
        decode: *const fn (Allocator, *RootCommand, DecodeSource) ?[]const u8,
        default_text: ?[]const u8,
        dotted_path: []const u8,
        field_path: []const []const u8,
        format_cli: bool,
        has_default: bool,
        kind: ValueKind,
        long: []const u8,
        parent_command: usize,
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
        if (@hasDecl(T, "format_cli")) {
            validate_format_cli(T, dotted_path);
        }
        if (@hasDecl(T, "decode_cli_arg")) {
            validate_decode_method(T, dotted_path, "decode_cli_arg");
            if (@hasDecl(T, "decode_cli_env")) {
                validate_decode_method(T, dotted_path, "decode_cli_env");
            }
            return true;
        }
        return false;
    }

    fn validate_decode_method(comptime T: type, comptime dotted_path: []const u8, comptime method_name: []const u8) void {
        const err = "Invalid cli interface definition for " ++ @typeName(T) ++ " found in " ++ dotted_path ++ ": ." ++ method_name ++ " ";
        const decl = @typeInfo(@TypeOf(@field(T, method_name)));
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

    fn validate_format_cli(comptime T: type, comptime dotted_path: []const u8) void {
        const err = "Invalid cli interface definition for " ++ @typeName(T) ++ " found in " ++ dotted_path ++ ": .format_cli ";
        const decl = @typeInfo(@TypeOf(T.format_cli));
        if (decl != .@"fn") {
            @compileError(err ++ "needs to be a method, not " ++ @tagName(decl));
        }
        const func = decl.@"fn";
        if (func.params.len != 1) {
            @compileError(err ++ "needs to take exactly 1 parameter: (self: " ++ @typeName(T) ++ "), not " ++ std.fmt.comptimePrint("{d}", .{func.params.len}));
        }
        if (func.params[0].type) |t| {
            if (t != T) {
                @compileError(err ++ "first parameter must be " ++ @typeName(T) ++ ", not " ++ @typeName(t));
            }
        }
        const Return = func.return_type orelse @compileError(err ++ "must have a concrete return type");
        switch (@typeInfo(Return)) {
            .pointer => |info| {
                if (!(info.size == .slice and info.child == u8)) {
                    @compileError(err ++ "must return []const u8, not " ++ @typeName(Return));
                }
            },
            else => @compileError(err ++ "must return []const u8, not " ++ @typeName(Return)),
        }
    }

    fn value_label(self: ValueKind, allocator: Allocator, app_name: []const u8) []const u8 {
        return switch (self) {
            .bool => "",
            .float => "float",
            .int => "int",
            .interface => "value",
            .optional => |inner| {
                const repr = inner.value_label(allocator, app_name);
                if (repr.len > 0) {
                    return std.fmt.allocPrint(allocator, "?{s}", .{repr}) catch oom(app_name);
                }
                return "";
            },
            .slice => |inner| {
                const repr = inner.value_label(allocator, app_name);
                if (repr.len > 0) {
                    return std.fmt.allocPrint(allocator, "[]{s}", .{repr}) catch oom(app_name);
                }
                return "[]bool";
            },
            .string => "string",
            .string_enum => "enum",
        };
    }
};

pub fn write_wrapped(writer: *std.Io.Writer, text: []const u8, spec: WrapSpec) !usize {
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
            col += word.len;
            first = false;
        } else if ((col + 1 + word.len) > spec.width) {
            try writer.writeByte('\n');
            _ = try writer.splatByte(' ', spec.indent);
            try writer.writeAll(word);
            col = spec.indent + word.len;
        } else {
            try writer.writeByte(' ');
            try writer.writeAll(word);
            col += 1 + word.len;
        }
    }
    return col;
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
                                    .bool => {
                                        break :blk true;
                                    },
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
            const format_cli = has_format_cli(field.type, kind);
            const default_text = if (has_default) get_default_text(kind, field, format_cli) else null;
            option_meta[option_idx.*] = .{
                .decode = construct_decode(RootCommand, field.type, kind, field_path),
                .default_text = default_text,
                .dotted_path = name,
                .field_path = field_path,
                .format_cli = format_cli,
                .has_default = has_default,
                .kind = kind,
                .long = snake_to_kebab(field.name),
                .parent_command = parent_command_idx.*,
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
            var raw: Inner = undefined;
            const err = decode_cli_env(Inner, inner.*, allocator, &raw, val);
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
            switch (cmd_err.kind) {
                .too_few_args => |args| {
                    try w.print("not enough arguments for command \"{s}\": needs at least {d} {s}", .{ cmd_err.command_path, args.min_args, pluralize(args.min_args, "argument", "arguments") });
                },
                .too_many_args => |args| {
                    try w.print("too many arguments for command \"{s}\": max is {d} {s}", .{ cmd_err.command_path, args.max_args, pluralize(args.max_args, "argument", "arguments") });
                },
                .unknown_subcommand => |unknown| {
                    try w.print("unknown command: \"{s}\" in \"{s}\"", .{ unknown.subcommand_name, cmd_err.command_path });
                    if (unknown.suggestions.len > 0) {
                        try w.print("\n\nDid you mean one of the following?\n\n", .{});
                        for (unknown.suggestions, 0..) |suggestion, i| {
                            if (i > 0) {
                                try w.print("\n", .{});
                            }
                            try w.print("\t{s} {s}", .{ cmd_err.command_path, suggestion });
                        }
                    }
                },
            }
        },
        .missing_definition => |definition| switch (definition) {
            .option => |option_name| {
                try w.print("missing explicit definition for option: {s}", .{option_name});
            },
            .subcommand => |subcommand_name| {
                try w.print("missing explicit definition for subcommand: {s}", .{subcommand_name});
            },
        },
        .option => |opt_err| {
            switch (opt_err.kind) {
                .invalid_value => |message| {
                    try w.print("invalid value for option \"{s}\" in \"{s}\": {s} ", .{ opt_err.option_name, opt_err.command_path, message });
                },
                .missing_required => {
                    try w.print("missing required option: \"{s}\" in \"{s}\"", .{ opt_err.option_name, opt_err.command_path });
                },
                .missing_value => {
                    try w.print("missing value for option \"{s}\" in \"{s}\"", .{ opt_err.option_name, opt_err.command_path });
                },
                .mutually_exclusive => |merr| {
                    try w.print("option \"{s}\" in \"{s}\" is mutually exclusive with \"{s}\"", .{ opt_err.option_name, opt_err.command_path, merr.related_option_name });
                },
                .unknown_option => |unknown| {
                    try w.print("unknown option: \"{s}\" in \"{s}\"", .{ opt_err.option_name, opt_err.command_path });
                    if (unknown.suggestions.len > 0) {
                        try w.print("\n\nDid you mean one of the following?\n\n", .{});
                        for (unknown.suggestions, 0..) |suggestion, i| {
                            if (i > 0) {
                                try w.print("\n", .{});
                            }
                            try w.print("\t{s} {s}", .{ opt_err.command_path, suggestion });
                        }
                    }
                },
                .unmet_dependency => |merr| {
                    try w.print("option \"{s}\" in \"{s}\" also needs \"{s}\"", .{ opt_err.option_name, opt_err.command_path, merr.related_option_name });
                },
            }
        },
        .raw => |message| {
            try w.print("{s}", .{message});
        },
        .validation => |validation| switch (validation) {
            .option => |v| {
                try w.print("invalid option definition for {s}: {s}", .{ v.option_name, v.message });
            },
            .subcommand => |v| {
                try w.print("invalid subcommand definition for {s}: {s}", .{ v.subcommand_name, v.message });
            },
        },
    }
    try w.print("\x1b[0m\n", .{});
    try w.flush();
}

fn default_print_help(allocator: Allocator, w: *std.Io.Writer, ctx: HelpContext) !void {
    const heading = ctx.style.heading;
    const heading_end = ctx.style.heading_end;
    const highlight = ctx.style.highlight;
    const highlight_end = ctx.style.highlight_end;
    const spec: WrapSpec = .{
        .indent = ctx.style.indent,
        .start_col = 0,
        .width = ctx.terminal_width,
    };
    var printed = false;
    if (ctx.command.prolog) |prolog| {
        try w.print("{s}\n", .{prolog});
        printed = true;
    }
    if (ctx.command.summary) |summary| {
        if (printed) {
            try w.print("\n", .{});
        }
        try w.print("{s}\n", .{summary});
        printed = true;
    }
    if (ctx.command.usage) |usage| {
        if (printed) {
            try w.print("\n", .{});
        }
        try w.print("{s}Usage:{s} {s}", .{ heading, heading_end, highlight });
        for (usage, 0..) |line, i| {
            if (i == 0) {
                _ = try write_wrapped(w, line, .{ .indent = 7, .start_col = 7, .width = spec.width });
                try w.print("\n", .{});
            } else {
                _ = try write_wrapped(w, line, .{ .indent = 7, .start_col = 0, .width = spec.width });
                try w.print("\n", .{});
            }
        }
        try w.print("{s}", .{highlight_end});
        printed = true;
    }
    if (ctx.command.description) |description| {
        if (printed) {
            try w.print("\n", .{});
        }
        try w.print("{s}Info:{s}\n", .{ heading, heading_end });
        _ = try write_wrapped(w, description, spec);
        try w.print("\n", .{});
        printed = true;
    }
    const opt_indent = spec.indent + 4 + 2 + ctx.max_option_width + 3;
    for (ctx.option_groups) |group| {
        if (group.items.len > 0) {
            if (printed) {
                try w.print("\n", .{});
            }
            const name = if (group.name.len > 0) group.name else "Options";
            try w.print("{s}{s}:{s}\n", .{ heading, name, heading_end });
            for (group.items) |opt| {
                _ = try w.splatByte(' ', spec.indent);
                if (opt.short) |short| {
                    try w.print("{s}-{c}{s}, ", .{ highlight, short, highlight_end });
                } else {
                    try w.print("    ", .{});
                }
                try w.print("{s}--{s} {s}{s}", .{ highlight, opt.long, opt.value_label, highlight_end });
                const start: usize = spec.indent + 4 + 2 + opt.long.len + 1 + opt.value_label.len;
                var col: usize = start;
                if (opt.summary) |summary| {
                    if (summary.len > 0) {
                        col = try write_wrapped(w, summary, .{ .indent = opt_indent, .start_col = start, .width = spec.width });
                    }
                }
                if (opt.default_text) |default_text| {
                    if (col > opt_indent) {
                        try w.print(" ", .{});
                    }
                    col = try write_wrapped(
                        w,
                        std.fmt.allocPrint(allocator, "(default: {s})", .{default_text}) catch oom(ctx.app_name),
                        .{ .indent = opt_indent, .start_col = col, .width = spec.width },
                    );
                }
                if (opt.deprecated) |deprecated| {
                    if (deprecated.len > 0) {
                        try w.print("{s}", .{ctx.style.deprecation});
                        if (col > opt_indent) {
                            try w.print(" ", .{});
                        }
                        col = try write_wrapped(
                            w,
                            std.fmt.allocPrint(allocator, "DEPRECATED: {s}", .{deprecated}) catch oom(ctx.app_name),
                            .{ .indent = opt_indent, .start_col = col, .width = spec.width },
                        );
                        try w.print("{s}", .{ctx.style.deprecation_end});
                    }
                }
                try w.print("\n", .{});
            }
            printed = true;
        }
    }
    const command_indent = spec.indent + ctx.max_subcommand_width + 3;
    for (ctx.subcommand_groups) |group| {
        if (group.items.len > 0) {
            if (printed) {
                try w.print("\n", .{});
            }
            const name = if (group.name.len > 0) group.name else "Commands";
            try w.print("{s}{s}:{s}\n", .{ heading, name, heading_end });
            for (group.items) |subcommand| {
                try w.print("{s}", .{highlight});
                _ = try write_wrapped(w, subcommand.name, spec);
                try w.print("{s}", .{highlight_end});
                if (subcommand.summary) |summary| {
                    const start = spec.indent + subcommand.name.len;
                    _ = try write_wrapped(w, summary, .{ .indent = command_indent, .start_col = start, .width = spec.width });
                }
                try w.print("\n", .{});
            }
            printed = true;
        }
    }
    if (ctx.has_subcommands) {
        if (ctx.command_path.len > 0) {
            try w.print("\nSee '{s}{s} help {s} <command>{s}' for more information on a specific command.\n", .{ highlight, ctx.app_name, ctx.command_path, highlight_end });
        } else {
            try w.print("\nSee '{s}{s} help <command>{s}' for more information on a specific command.\n", .{ highlight, ctx.app_name, highlight_end });
        }
    }
    if (ctx.command.epilog) |epilog| {
        if (printed) {
            try w.print("\n", .{});
        }
        try w.print("{s}\n", .{epilog});
        printed = true;
    }
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

fn get_default_text(comptime kind: ValueKind, comptime field: std.builtin.Type.StructField, comptime format_cli: bool) ?[]const u8 {
    // NOTE(tav): We bail on any .interface kinds.
    return switch (kind) {
        .bool => if (field.defaultValue().?) "true" else "false",
        .float => std.fmt.comptimePrint("{}", .{field.defaultValue().?}),
        .int => std.fmt.comptimePrint("{d}", .{field.defaultValue().?}),
        .interface => {
            if (format_cli) {
                return field.type.format_cli(field.defaultValue().?);
            }
            return null;
        },
        .optional => |inner| if (field.defaultValue().? == null) "null" else switch (inner.*) {
            .bool => if (field.defaultValue().?.? == true) "true" else "false",
            .float => std.fmt.comptimePrint("{}", .{field.defaultValue().?.?}),
            .int => std.fmt.comptimePrint("{d}", .{field.defaultValue().?.?}),
            .interface => {
                if (format_cli) {
                    const val = field.defaultValue().?;
                    if (val != null) {
                        return @typeInfo(field.type).optional.child.format_cli(field.defaultValue().?.?);
                    }
                }
                return null;
            },
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
                        .bool => if (elem) "true" else "false",
                        .float => std.fmt.comptimePrint("{}", .{elem}),
                        .int => std.fmt.comptimePrint("{d}", .{elem}),
                        .interface => fblk: {
                            if (format_cli) {
                                break :fblk @typeInfo(field.type).pointer.child.format_cli(elem);
                            }
                            return null;
                        },
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

fn has_format_cli(comptime T: type, comptime kind: ValueKind) bool {
    return switch (kind) {
        .interface => @hasDecl(T, "format_cli"),
        .optional => |inner| has_format_cli(@typeInfo(T).optional.child, inner.*),
        .slice => |inner| has_format_cli(@typeInfo(T).pointer.child, inner.*),
        else => false,
    };
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

fn pluralize(count: usize, singular: []const u8, plural: []const u8) []const u8 {
    return if (count == 1) singular else plural;
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

fn unqualified_type_name(comptime T: type) []const u8 {
    const name = @typeName(T);
    return if (std.mem.lastIndexOfScalar(u8, name, '.')) |idx| name[idx + 1 ..] else name;
}

const testing = std.testing;

fn expect_missing_option(result: anytype, expected_path: []const u8) !void {
    defer free_ok(result);
    switch (result) {
        .err => |err| switch (err) {
            .missing_definition => |d| switch (d) {
                .option => |name| try testing.expectEqualStrings(expected_path, name),
                .subcommand => return error.ExpectedOption,
            },
            else => return error.ExpectedMissingDefinition,
        },
        .ok => return error.ExpectedError,
    }
}

fn expect_missing_subcommand(result: anytype, expected_path: []const u8) !void {
    defer free_ok(result);
    switch (result) {
        .err => |err| switch (err) {
            .missing_definition => |d| switch (d) {
                .subcommand => |name| try testing.expectEqualStrings(expected_path, name),
                .option => return error.ExpectedSubcommand,
            },
            else => return error.ExpectedMissingDefinition,
        },
        .ok => return error.ExpectedError,
    }
}

fn expect_ok(result: anytype) !void {
    switch (result) {
        .ok => |r| {
            r.arena.deinit();
            testing.allocator.destroy(r.arena);
        },
        .err => return error.ExpectedOk,
    }
}

fn expect_validation_option_error(result: anytype, expected_path: []const u8) !void {
    defer free_ok(result);
    switch (result) {
        .err => |err| switch (err) {
            .validation => |v| switch (v) {
                .option => |o| try testing.expectEqualStrings(expected_path, o.option_name),
                .subcommand => return error.ExpectedOptionError,
            },
            else => return error.ExpectedValidationError,
        },
        .ok => return error.ExpectedError,
    }
}

fn expect_validation_subcommand_error(result: anytype, expected_path: []const u8) !void {
    defer free_ok(result);
    switch (result) {
        .err => |err| switch (err) {
            .validation => |v| switch (v) {
                .subcommand => |s| try testing.expectEqualStrings(expected_path, s.subcommand_name),
                .option => return error.ExpectedSubcommandError,
            },
            else => return error.ExpectedValidationError,
        },
        .ok => return error.ExpectedError,
    }
}

fn free_ok(result: anytype) void {
    switch (result) {
        .ok => |r| {
            r.arena.deinit();
            testing.allocator.destroy(r.arena);
        },
        .err => {},
    }
}

fn test_parse_raw(app: anytype) @TypeOf(app.parse_raw(undefined, undefined, undefined)) {
    const arena = testing.allocator.create(std.heap.ArenaAllocator) catch unreachable;
    arena.* = std.heap.ArenaAllocator.init(testing.allocator);
    const result = app.parse_raw(arena, &.{}, .empty);
    switch (result) {
        .ok => return result,
        .err => {
            arena.deinit();
            testing.allocator.destroy(arena);
            return result;
        },
    }
}

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

test "option enum includes nested" {
    const Root = struct {
        Foo: struct {
            bar: bool = false,
        },
        baz: i64 = 0,
    };
    const fields = @typeInfo(Option(Root)).@"enum".fields;
    try testing.expectEqual(@as(usize, 2), fields.len);
    try testing.expectEqualStrings("Foo_bar", fields[0].name);
    try testing.expectEqualStrings("baz", fields[1].name);
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

test "empty subcommand name" {
    const Root = struct { Foo: struct {} };
    var app = App(Root).init(.{ .name = "test" });
    app.subcommand(.Foo, .{ .name = "" });
    try expect_validation_subcommand_error(test_parse_raw(&app), "Root.Foo");
}

test "subcommand name conflict" {
    const Root = struct {
        Foo: struct {},
        Bar: struct {},
    };
    var app = App(Root).init(.{ .name = "test" });
    app.subcommand(.Foo, .{ .name = "baz" });
    app.subcommand(.Bar, .{ .name = "baz" });
    try expect_validation_subcommand_error(test_parse_raw(&app), "Root.Bar");
}

test "min_args with supports_positional_args false" {
    const Root = struct { Foo: struct {} };
    var app = App(Root).init(.{ .name = "test" });
    app.subcommand(.Foo, .{ .supports_positional_args = false, .min_args = 1 });
    try expect_validation_subcommand_error(test_parse_raw(&app), "Root.Foo");
}

test "max_args with supports_positional_args false" {
    const Root = struct { Foo: struct {} };
    var app = App(Root).init(.{ .name = "test" });
    app.subcommand(.Foo, .{ .supports_positional_args = false, .max_args = 1 });
    try expect_validation_subcommand_error(test_parse_raw(&app), "Root.Foo");
}

test "builtin help command conflict" {
    const Root = struct { Help: struct {} };
    var app = App(Root).init(.{ .name = "test", .enable_help_command = true });
    app.subcommand(.Help, .{ .name = "help" });
    try expect_validation_subcommand_error(test_parse_raw(&app), "Root.Help");
}

test "builtin version command conflict" {
    const Root = struct { Version: struct {} };
    var app = App(Root).init(.{ .name = "test", .version = "1.0" });
    app.subcommand(.Version, .{ .name = "version" });
    try expect_validation_subcommand_error(test_parse_raw(&app), "Root.Version");
}

test "alias conflict with existing subcommand" {
    const Root = struct {
        Foo: struct {},
        Bar: struct {},
    };
    var app = App(Root).init(.{ .name = "test" });
    app.subcommand(.Foo, .{ .aliases = &.{"bar"} });
    app.subcommand(.Bar, .{});
    try expect_validation_subcommand_error(test_parse_raw(&app), "Root.Foo");
}

test "long option conflicts with --help" {
    const Root = struct { help_me: bool = false };
    var app = App(Root).init(.{ .name = "test" });
    app.option(.help_me, .{ .long = "help" });
    try expect_validation_option_error(test_parse_raw(&app), "Root.help_me");
}

test "short option conflicts with -h" {
    const Root = struct { foo: bool = false };
    var app = App(Root).init(.{ .name = "test" });
    app.option(.foo, .{ .short = 'h' });
    try expect_validation_option_error(test_parse_raw(&app), "Root.foo");
}

test "long alias conflicts with --help" {
    const Root = struct { foo: bool = false };
    var app = App(Root).init(.{ .name = "test" });
    app.option(.foo, .{ .long_aliases = &.{"help"} });
    try expect_validation_option_error(test_parse_raw(&app), "Root.foo");
}

test "long option starts with hyphen" {
    const Root = struct { foo: bool = false };
    var app = App(Root).init(.{ .name = "test" });
    app.option(.foo, .{ .long = "-bad" });
    try expect_validation_option_error(test_parse_raw(&app), "Root.foo");
}

test "long option is single character" {
    const Root = struct { foo: bool = false };
    var app = App(Root).init(.{ .name = "test" });
    app.option(.foo, .{ .long = "x" });
    try expect_validation_option_error(test_parse_raw(&app), "Root.foo");
}

test "long option contains invalid character" {
    const Root = struct { foo: bool = false };
    var app = App(Root).init(.{ .name = "test" });
    app.option(.foo, .{ .long = "f@o" });
    try expect_validation_option_error(test_parse_raw(&app), "Root.foo");
}

test "short option conflicts with existing" {
    const Root = struct { foo: bool = false, bar: bool = false };
    var app = App(Root).init(.{ .name = "test" });
    app.option(.foo, .{ .short = 'x' });
    app.option(.bar, .{ .short = 'x' });
    try expect_validation_option_error(test_parse_raw(&app), "Root.bar");
}

test "long option conflicts with existing" {
    const Root = struct { foo: bool = false, bar: bool = false };
    var app = App(Root).init(.{ .name = "test" });
    app.option(.foo, .{});
    app.option(.bar, .{ .long = "foo" });
    try expect_validation_option_error(test_parse_raw(&app), "Root.bar");
}

test "negatable only valid for bool" {
    const Root = struct { foo: []const u8 = "x" };
    var app = App(Root).init(.{ .name = "test" });
    app.option(.foo, .{ .negatable = true });
    try expect_validation_option_error(test_parse_raw(&app), "Root.foo");
}

test "required false without default" {
    const Root = struct { foo: i64 };
    var app = App(Root).init(.{ .name = "test" });
    app.option(.foo, .{ .required = false });
    try expect_validation_option_error(test_parse_raw(&app), "Root.foo");
}

test "option depends on itself" {
    const Root = struct { foo: bool = false };
    var app = App(Root).init(.{ .name = "test" });
    app.option(.foo, .{ .depends_on = &.{.foo} });
    try expect_validation_option_error(test_parse_raw(&app), "Root.foo");
}

test "option mutually exclusive with itself" {
    const Root = struct { foo: bool = false };
    var app = App(Root).init(.{ .name = "test" });
    app.option(.foo, .{ .mutually_exclusive_with = &.{.foo} });
    try expect_validation_option_error(test_parse_raw(&app), "Root.foo");
}

test "depends on non-inherited cross-command option" {
    const Root = struct {
        Foo: struct { bar: bool = false },
        baz: bool = false,
    };
    var app = App(Root).init(.{ .name = "test" });
    app.subcommand(.Foo, .{});
    app.option(.Foo_bar, .{ .depends_on = &.{.baz} });
    app.option(.baz, .{});
    try expect_validation_option_error(test_parse_raw(&app), "Root.Foo.bar");
}

test "long alias empty string" {
    const Root = struct { foo: bool = false };
    var app = App(Root).init(.{ .name = "test" });
    app.option(.foo, .{ .long_aliases = &.{""} });
    try expect_validation_option_error(test_parse_raw(&app), "Root.foo");
}

test "long alias single character" {
    const Root = struct { foo: bool = false };
    var app = App(Root).init(.{ .name = "test" });
    app.option(.foo, .{ .long_aliases = &.{"x"} });
    try expect_validation_option_error(test_parse_raw(&app), "Root.foo");
}

test "long alias starts with hyphen" {
    const Root = struct { foo: bool = false };
    var app = App(Root).init(.{ .name = "test" });
    app.option(.foo, .{ .long_aliases = &.{"-bad"} });
    try expect_validation_option_error(test_parse_raw(&app), "Root.foo");
}

test "inherited option shadows error" {
    const Root = struct {
        Foo: struct { verbose: bool = false },
        verbose: bool = false,
    };
    var app = App(Root).init(.{ .name = "test" });
    app.subcommand(.Foo, .{});
    app.option(.Foo_verbose, .{});
    app.option(.verbose, .{ .inherited = true });
    try expect_validation_option_error(test_parse_raw(&app), "Root.Foo.verbose");
}

test "missing explicit subcommand definition" {
    const Root = struct { Foo: struct {} };
    var app = App(Root).init(.{ .name = "test" });
    app.require_explicit_definitions();
    try expect_missing_subcommand(test_parse_raw(&app), "Root.Foo");
}

test "missing explicit option definition" {
    const Root = struct { foo: bool = false };
    var app = App(Root).init(.{ .name = "test" });
    app.require_explicit_definitions();
    try expect_missing_option(test_parse_raw(&app), "Root.foo");
}

test "basic valid app resolves" {
    const Root = struct {
        Foo: struct {
            bar: bool = false,
        },
        verbose: bool = false,
    };
    var app = App(Root).init(.{ .name = "test" });
    app.subcommand(.Foo, .{ .summary = "do foo" });
    app.option(.Foo_bar, .{ .short = 'b' });
    app.option(.verbose, .{ .short = 'v', .inherited = true });
    try expect_ok(test_parse_raw(&app));
}

test "negatable bool with default true" {
    const Root = struct { color: bool = true };
    var app = App(Root).init(.{ .name = "test" });
    app.option(.color, .{});
    try expect_ok(test_parse_raw(&app));
}

test "slice option resolves" {
    const Root = struct { tags: []const []const u8 = &.{} };
    var app = App(Root).init(.{ .name = "test" });
    app.option(.tags, .{});
    try expect_ok(test_parse_raw(&app));
}

test "optional field resolves" {
    const Root = struct { port: ?u16 = null };
    var app = App(Root).init(.{ .name = "test" });
    app.option(.port, .{});
    try expect_ok(test_parse_raw(&app));
}

test "subcommand aliases resolve" {
    const Root = struct {
        Foo: struct {},
        Bar: struct {},
    };
    var app = App(Root).init(.{ .name = "test" });
    app.subcommand(.Foo, .{ .aliases = &.{"f"} });
    app.subcommand(.Bar, .{});
    try expect_ok(test_parse_raw(&app));
}

test "env var prefix generates env vars" {
    const Root = struct { foo_bar: []const u8 = "x" };
    var app = App(Root).init(.{ .name = "test", .env_var_prefix = "MYAPP" });
    app.option(.foo_bar, .{});
    try expect_ok(test_parse_raw(&app));
}

test "empty string default shows quotes" {
    const Root = struct { foo: []const u8 = "" };
    var app = App(Root).init(.{ .name = "test", .show_defaults = true });
    app.option(.foo, .{});
    try expect_ok(test_parse_raw(&app));
}

const Duration = struct {
    value: i64,

    pub fn decode_cli_arg(allocator: Allocator, raw: []const u8) DecodeResult(Duration) {
        _ = allocator;
        _ = raw;
        return .{ .ok = Duration{ .value = 1 } };
    }

    pub fn format_cli(self: Duration) []const u8 {
        _ = self;
        return std.fmt.comptimePrint("1h1m1s", .{});
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
    host: []const u8,
    duration: f64,
    timeout: Duration,
};

const MySubcommandGroup = enum {
    Server_Commands,
};

const MyOptionGroup = enum {
    Deploy_Options,
};

pub fn main(init: std.process.Init) !void {
    var app = AppWithGroups(
        MyApp,
        MySubcommandGroup,
        MyOptionGroup,
    ).init(.{
        .name = "kickass",
        .show_defaults = true,
        .global_epilog = "This is an epilog",
        .global_prolog = "This is a prolog",
        .description = "This is a description",
        .summary = "This is a summary",
        .usage = .{ .positional_args = "<input>" },
        .help_style = .plain,
    });

    app.subcommand(.Foo, .{
        .summary = "Foo command",
        .name = "fx",
        .group = .Server_Commands,
        // .supports_positional_args = false,
        // .max_args = 1,
    });
    app.option(.Foo_baz, .{
        .deprecated = "Use --foo instead",
        // .mutually_exclusive_with = &.{.Foo_meow},
        // .depends_on = &.{.Boom_hmz},
    });
    app.option(.host, .{ .group = .Deploy_Options });
    app.option(.Boom_hmz, .{ .inherited = true });
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

    // try app.print_help(init.gpa, init.io, .Default);
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
