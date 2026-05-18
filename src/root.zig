const std = @import("std");

pub const VM = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) VM {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *VM) void {
        _ = self;
    }

    pub fn interpret(self: *VM, source: []const u8) !void {
        _ = self;
        std.debug.print("Lil interpret : {s}\n", .{source});
    }
};

test "init VM" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    try vm.interpret("let x = 5");
}

