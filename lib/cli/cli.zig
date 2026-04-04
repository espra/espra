// Public Domain (-) 2026-present, The Espra Core Authors.
// See the Espra Core UNLICENSE file for details.

const builtin = @import("builtin");
const std = @import("std");

const Allocator = std.mem.Allocator;
const EnumField = std.builtin.Type.EnumField;

pub const ParseError = error{
    InvalidOption,
    InvalidSubcommand,
    MissingRequired,
};

const min_terminal_width: u16 = 80;

pub fn AppOptions(comptime RootCommand: type) type {
    return struct {
        allocator: ?Allocator = null,
        complete: Completer(RootCommand) = null,
        description: ?[]const u8 = null,
        enable_completion_command: bool = false,
        enable_help_command: bool = false,
        env_var_prefix: ?[]const u8 = null,
        epilog: ?[]const u8 = null,
        format_error: ?*const fn (*std.Io.Writer, ErrorContext(RootCommand)) anyerror!void = null,
        format_help: ?*const fn (*std.Io.Writer, HelpContext(RootCommand)) anyerror!void = null,
        max_args: ?usize = null,
        min_args: ?usize = null,
        name: []const u8,
        preserve_unmatched_short_options: bool = false,
        prolog: ?[]const u8 = null,
        show_defaults: ?bool = null,
        summary: ?[]const u8 = null,
        usage: ?Usage = null,
        version: ?[]const u8 = null,
    };
}

pub fn App(comptime RootCommand: type) type {
    return AppWithGroups(RootCommand, void, void);
}

pub fn AppWithGroups(comptime RootCommand: type, comptime CommandGroup: type, comptime OptionGroup: type) type {
    if (CommandGroup != void and @typeInfo(CommandGroup) != .@"enum") {
        @compileError("CommandGroup must be an enum type");
    }
    if (OptionGroup != void and @typeInfo(OptionGroup) != .@"enum") {
        @compileError("OptionGroup must be an enum type");
    }
    const AppOpts = AppOptions(RootCommand);
    return struct {
        arena: std.heap.ArenaAllocator,
        backing_allocator: ?*std.heap.DebugAllocator(.{}),
        options: AppOpts,

        const Self = @This();

        pub fn init(options: AppOptions(RootCommand)) *Self {
            var backing_allocator: ?*std.heap.DebugAllocator(.{}) = if (builtin.mode == .Debug) blk: {
                if (options.allocator != null) {
                    break :blk null;
                }
                const raw = std.heap.page_allocator.create(std.heap.DebugAllocator(.{})) catch oom(options.name);
                raw.* = .init;
                break :blk raw;
            } else null;
            const allocator = options.allocator orelse if (builtin.mode == .Debug)
                backing_allocator.?.allocator()
            else
                std.heap.smp_allocator;
            const self = allocator.create(Self) catch oom(options.name);
            self.* = .{
                .arena = std.heap.ArenaAllocator.init(allocator),
                .backing_allocator = backing_allocator,
                .options = options,
            };
            return self;
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.arena.child_allocator;
            const backing = self.backing_allocator;
            self.arena.deinit();
            allocator.destroy(self);
            if (backing) |backing_allocator| {
                _ = backing_allocator.deinit();
                std.heap.page_allocator.destroy(backing_allocator);
            }
        }

        pub fn option(self: *Self, opt: Option(RootCommand), info: OptionInfo(RootCommand, OptionGroup)) void {
            _ = self;
            _ = opt;
            _ = info;
        }

        pub fn parse(self: *Self) SuccessResult(RootCommand) {
            // const args = try std.process.argsAlloc(allocator);
            // defer std.process.argsFree(allocator, args);
            _ = self;
            return .{
                .args = &.{},
                .invoked_command = .Default,
                .root = undefined,
                // .root = self.root,
                .unmatched_short_options = null,
                .warnings = &.{},
            };
        }

        pub fn require_explicit_definitions(self: *Self) void {
            _ = self;
        }

        pub fn subcommand(self: *Self, cmd: Subcommand(RootCommand), info: CommandInfo(RootCommand, CommandGroup)) void {
            _ = self;
            _ = cmd;
            _ = info;
        }
    };
}

pub const CommandError = struct {
    command_path: []const u8,
    kind: Kind,
    message: []const u8,

    pub const Kind = union(enum) {
        missing_explicit_definition: union(enum) {
            option: []const u8,
            subcommand: []const u8,
        },
        too_few_args: struct { min_args: usize },
        too_many_args: struct { max_args: usize },
        unknown_option: struct { option_name: []const u8 },
        unknown_subcommand: struct { subcommand_name: []const u8 },
    };
};

pub const CommandHelpEntry = struct {
    description: ?[]const u8 = null,
    epilog: ?[]const u8 = null,
    prolog: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    usage: ?[]const u8 = null,
};

pub fn CommandInfo(comptime RootCommand: type, comptime CommandGroup: type) type {
    return struct {
        aliases: []const Subcommand(RootCommand) = &.{},
        complete: Completer(RootCommand) = null,
        deprecated: ?[]const u8 = null,
        description: ?[]const u8 = null,
        epilog: ?[]const u8 = null,
        group: ?CommandGroup = null,
        hidden: bool = false,
        max_args: ?usize = null,
        min_args: ?usize = null,
        name: ?[]const u8 = null,
        preserve_unmatched_short_options: bool = false,
        prolog: ?[]const u8 = null,
        summary: ?[]const u8 = null,
        usage: ?Usage = null,
    };
}

pub const CommandWarning = struct {
    command_path: []const u8,
    message: []const u8,
};

pub fn Completer(comptime RootCommand: type) type {
    return ?*const fn (
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

pub fn ErrorContext(comptime RootCommand: type) type {
    return struct {
        app: AppOptions(RootCommand),
        command_path: []const u8,
        message: []const u8,
        usage: ?[]const u8,
        warning: bool,
    };
}

pub const ErrorResult = union(enum) {
    command: CommandError,
    option: OptionError,
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
    comptime var field_values: [count]u16 = undefined;
    comptime var i: usize = 1;
    field_names[0] = "Default";
    field_values[0] = 0;
    construct_command_enum(RootCommand, "", &field_names, &field_values, &i);
    return @Enum(u16, .exhaustive, &field_names, &field_values);
}

pub fn Option(comptime RootCommand: type) type {
    const count = find_options(RootCommand, "");
    comptime var field_names: [count][]const u8 = undefined;
    comptime var field_values: [count]u32 = undefined;
    comptime var i: usize = 0;
    construct_option_enum(RootCommand, "", &field_names, &field_values, &i);
    return @Enum(u32, .exhaustive, &field_names, &field_values);
}

pub const OptionError = struct {
    command_path: []const u8,
    kind: Kind,
    message: []const u8,
    option_name: []const u8,

    pub const Kind = union(enum) {
        invalid_value,
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
        complete: Completer(RootCommand) = null,
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

pub const OptionWarning = struct {
    command_path: []const u8,
    message: []const u8,
    option_name: []const u8,
};

pub const ParseResult = union(enum) {
    err: ErrorResult,
    ok: SuccessResult,
};

pub fn Subcommand(comptime RootCommand: type) type {
    const count = find_subcommands(RootCommand, "");
    comptime var field_names: [count][]const u8 = undefined;
    comptime var field_values: [count]u16 = undefined;
    comptime var i: usize = 0;
    construct_command_enum(RootCommand, "", &field_names, &field_values, &i);
    return @Enum(u16, .exhaustive, &field_names, &field_values);
}

pub const SubcommandHelpEntry = struct {
    deprecated: ?[]const u8 = null,
    hidden: bool = false,
    name: []const u8,
    summary: ?[]const u8 = null,
};

pub fn SuccessResult(comptime RootCommand: type) type {
    return struct {
        args: []const []const u8,
        invoked_command: InvokedCommand(RootCommand),
        root: *RootCommand,
        unmatched_short_options: ?[]const u8,
        warnings: []const Warning,
    };
}

pub const Usage = union(enum) {
    args: []const u8,
    full_text: []const u8,
};

pub const Warning = union(enum) {
    command: CommandWarning,
    option: OptionWarning,
};

fn construct_command_enum(comptime T: type, comptime prefix: []const u8, field_names: [][]const u8, field_values: []u16, next: *usize) void {
    const fields = @typeInfo(T).@"struct".fields;
    for (fields) |field| {
        if (!std.ascii.isUpper(field.name[0])) {
            continue;
        }
        const name = if (prefix.len == 0) field.name else prefix ++ "_" ++ field.name;
        field_names[next.*] = name;
        field_values[next.*] = next.*;
        next.* += 1;
        construct_command_enum(field.type, name, field_names, field_values, next);
    }
}

fn construct_option_enum(comptime T: type, comptime prefix: []const u8, field_names: [][]const u8, field_values: []u32, next: *usize) void {
    const fields = @typeInfo(T).@"struct".fields;
    for (fields) |field| {
        if (std.ascii.isUpper(field.name[0])) {
            const name = if (prefix.len == 0) field.name ++ "_" else prefix ++ field.name ++ "_";
            construct_option_enum(field.type, name, field_names, field_values, next);
        } else {
            field_names[next.*] = prefix ++ field.name;
            field_values[next.*] = next.*;
            next.* += 1;
        }
    }
}

fn exit_error(app_name: []const u8, message: []const u8) noreturn {
    std.debug.print("\x1b[31m!! ERROR: {s}: {s} !!\x1b[0m\n", .{ app_name, message });
    std.process.exit(1);
}

fn exit_errorf(app_name: []const u8, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("\x1b[31m!! ERROR: {s}: ", .{app_name});
    std.debug.print(fmt, args);
    std.debug.print("\x1b[0m\n", .{});
    std.process.exit(1);
}

fn find_options(comptime T: type, comptime prefix: []const u8) usize {
    const fields = switch (@typeInfo(T)) {
        .@"struct" => |info| info.fields,
        else => @compileError("Expected struct type for RootCommand" ++ prefix ++ ", got " ++ @typeName(T)),
    };
    var count: usize = 0;
    for (fields) |field| {
        if (std.ascii.isUpper(field.name[0])) {
            count += find_options(field.type, prefix ++ "." ++ field.name);
        } else {
            count += 1;
        }
    }
    return count;
}

fn find_subcommands(comptime T: type, comptime prefix: []const u8) usize {
    const fields = switch (@typeInfo(T)) {
        .@"struct" => |info| info.fields,
        else => @compileError("Expected struct type for RootCommand" ++ prefix ++ ", got " ++ @typeName(T)),
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

fn oom(app_name: []const u8) noreturn {
    exit_error(app_name, "out of memory (OOM)");
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

pub fn main() !void {
    var app = App(MyApp).init(.{
        .name = "kickass",
    });
    defer app.deinit();

    app.subcommand(.Foo, .{ .summary = "Foo command" });
    app.option(.spam, .{ .summary = "option" });
    app.option(.Foo_Bar_hello, .{ .summary = "option" });

    const result = app.parse();
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
