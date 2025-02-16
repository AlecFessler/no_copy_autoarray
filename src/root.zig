pub const AutoArray = @import("autoarray.zig").AutoArray;

test {
    @import("std").testing.refAllDecls(@This());
}
