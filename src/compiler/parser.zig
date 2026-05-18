const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

pub const Parser = struct {
    const Self = @This();

    scanner: *lexer.Lexer,
    arena: std.mem.Allocator,
    current: lexer.Token,
    previous: lexer.Token,
    had_error: bool,

    pub fn init(scanner: *lexer.Lexer, arena: std.mem.Allocator) Self {
        return .{
            .scanner = scanner,
            .arena = arena,
            .current = undefined,
            .previous = undefined,
            .had_error = false,
        };
    }

    fn advance(self: *Self) void {
        self.previous = self.current;

        while (true) {
            self.current = self.scanner.next();
            if (self.current.tag != .Error) break;

            self.had_error = true;
        }
    }

    fn match(self: *Self, tag: lexer.TokenType) bool {
        if (self.current.tag != tag) return false;
        self.advance();
        return true;
    }

    fn consume(self: *Self, tag: lexer.TokenType, message: []const u8) void {
        if (self.current.tag == tag) {
            self.advance();
            return;
        }

        std.debug.print("Synthax error on line {d}: {s}\n", .{ self.current.line, message });
        self.had_error = true;
    }
};
