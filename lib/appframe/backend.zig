const builtin = @import("builtin");

pub const impl = switch (builtin.os.tag) {
    .macos => @import("backend/macos.zig"),
    .ios => @import("backend/ios.zig"),
    else => @import("backend/stub.zig"),
};
