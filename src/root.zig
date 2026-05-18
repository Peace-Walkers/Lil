const std = @import("std");
const lexer = @import("compiler/lexer.zig");

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
        var scanner = lexer.Lexer.init(source);
        const is_testing = @import("builtin").is_test;
        if (!is_testing)
            std.debug.print("====TOKENS====\n", .{});

        while (true) {
            const token = scanner.next();

            if (!is_testing)
                std.debug.print("[{s:<15}] '{s}' (line {d})\n", .{ @tagName(token.tag), token.lexeme, token.line });

            if (token.tag == .Eof or token.tag == .Error) {
                break;
            }
        }

        if (!is_testing)
            std.debug.print("=================\n", .{});

        // std.debug.print("Lil interpret : {s}\n", .{source});
    }
};

test "init VM" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    try vm.interpret("let x = 5");
}

test {
    _ = @import("compiler/lexer.zig");
}

