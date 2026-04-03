// Public Domain (-) 2026-present, The Espra Core Authors.
// See the Espra Core UNLICENSE file for details.

const std = @import("std");

const Allocator = std.mem.Allocator;
const EnumField = std.builtin.Type.EnumField;

pub const AppOptions = struct {
    description: ?[]const u8 = null,
    enable_completion_command: bool = false,
    enable_help_command: bool = false,
    env_var_prefix: ?[]const u8 = null,
    epilog: ?[]const u8 = null,
    max_args: ?usize = null,
    min_args: ?usize = null,
    name: ?[]const u8 = null,
    preserve_unmatched_short_options: bool = false,
    prolog: ?[]const u8 = null,
    show_defaults: ?bool = null,
    summary: ?[]const u8 = null,
    usage: ?Usage = null,
    version: ?[]const u8 = null,
};

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
    return struct {
        arena: std.heap.ArenaAllocator,
        args: []const []const u8,
        invoked_command: InvokedCommand(RootCommand),
        options: AppOptions,
        root: *RootCommand,
        unmatched_short_options: ?[]const u8,

        const Self = @This();

        pub fn init(allocator: Allocator, options: AppOptions) !Self {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const root = try arena.allocator().create(RootCommand);
            return .{
                .arena = arena,
                .args = &.{},
                .invoked_command = .Default,
                .options = options,
                .root = root,
                .unmatched_short_options = null,
            };
        }

        pub fn deinit(self: Self) void {
            self.arena.deinit();
        }

        pub fn option(self: *Self, opt: Option(RootCommand), info: OptionInfo(RootCommand, OptionGroup)) void {
            _ = self;
            _ = opt;
            _ = info;
        }

        pub fn parse(self: *Self) !void {
            // const args = try std.process.argsAlloc(allocator);
            // defer std.process.argsFree(allocator, args);
            _ = self;
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

pub fn CommandInfo(comptime RootCommand: type, comptime CommandGroup: type) type {
    return struct {
        aliases: []const InvokedCommand(RootCommand) = &.{},
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

pub fn OptionInfo(comptime RootCommand: type, comptime OptionGroup: type) type {
    return struct {
        default_text: ?[]const u8 = null,
        deprecated: ?[]const u8 = null,
        env_var: ?[]const u8 = null,
        group: ?OptionGroup = null,
        hidden: bool = false,
        inherited: bool = false,
        long: ?[]const u8 = null,
        long_aliases: []const []const u8 = &.{},
        mutually_exclusive_with: []const Option(RootCommand) = &.{},
        required: bool = false,
        requires: []const Option(RootCommand) = &.{},
        short: ?u8 = null,
        show_default: ?bool = null,
        summary: ?[]const u8 = null,
        value_label: ?[]const u8 = null,
    };
}

pub fn Subcommand(comptime RootCommand: type) type {
    const count = find_subcommands(RootCommand, "");
    comptime var field_names: [count][]const u8 = undefined;
    comptime var field_values: [count]u16 = undefined;
    comptime var i: usize = 0;
    construct_command_enum(RootCommand, "", &field_names, &field_values, &i);
    return @Enum(u16, .exhaustive, &field_names, &field_values);
}

pub const Usage = union(enum) {
    args: []const u8,
    full_text: []const u8,
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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var app = try App(MyApp).init(allocator, .{});
    defer app.deinit();
    app.subcommand(.Foo, .{ .summary = "Foo command" });
    app.option(.spam, .{ .summary = "option" });
    app.option(.Foo_Bar_hello, .{ .summary = "option" });
    switch (app.invoked_command) {
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
