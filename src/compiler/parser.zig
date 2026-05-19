const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

pub const ParseError = error{
    SyntaxError,
    OutOfMemory,
    Overflow,
    InvalidCharacter,
};

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

    fn consume(self: *Self, tag: lexer.TokenType, message: []const u8) !void {
        if (self.current.tag == tag) {
            self.advance();
            return;
        }

        std.debug.print("Syntax error on line {d}: {s}\n", .{ self.current.line, message });
        self.had_error = true;
        return error.SyntaxError;
    }

    fn pase_decl(self: *Self) !ast.Node {
        if (self.match(.Let)) {
            try self.consume(.Identifier, "Expected variable name after 'let'.");
            const name = self.previous.lexeme;

            try self.consume(.Equals, "Expected equal sign after a variable name in assignation.");

            const value_node = try self.parse_expr();

            const heap_node = try self.arena.create(ast.Node);
            heap_node.* = value_node;

            if (self.current.tag != .Eof) {
                try self.consume(.NewLine, "Expected newline after variable declaration.");
            }

            return .{ .LetDeclaration = .{ .name = name, .initializer = heap_node } };
        }

        if (self.match(.Mut)) {
            try self.consume(.Identifier, "Expected variable name after 'let'.");
            const name = self.previous.lexeme;

            try self.consume(.Equals, "Expected equal sign after a variable name in assignation.");

            const value_node = try self.parse_expr();

            const heap_node = try self.arena.create(ast.Node);
            heap_node.* = value_node;

            if (self.current.tag != .Eof) {
                try self.consume(.NewLine, "Expected newline after variable declaration.");
            }

            return .{ .MutDeclaration = .{ .name = name, .initializer = heap_node } };
        }

        return .{ .Identifier = "Unknown Statement" };
    }

    fn parse_primary(self: *Self) ParseError!ast.Node {
        if (self.match(.Number)) return .{ .Number = try std.fmt.parseInt(i64, self.previous.lexeme, 10) };
        if (self.match(.String)) return .{ .String = self.previous.lexeme };
        if (self.match(.True) or self.match(.False)) return .{ .Boolean = self.previous.tag == .True };
        if (self.match(.Identifier)) return .{ .Identifier = self.previous.lexeme };

        if (self.match(.LParen)) {
            const expr = try self.parse_expr();
            try self.consume(.RParen, "Expected ')' after expression.");
            return expr;
        }

        return .{ .Identifier = "Expected a litteral value" };
    }

    fn parse_logical_or(self: *Self) ParseError!ast.Node {
        var expr = try self.parse_logical_and();

        while (self.match(.Or)) {
            const operator = self.previous.tag;

            const right = try self.parse_logical_and();

            const left_ptr = try self.arena.create(ast.Node);
            left_ptr.* = expr;

            const right_ptr = try self.arena.create(ast.Node);
            right_ptr.* = right;

            expr = .{ .Binary = .{ .left = left_ptr, .operator = operator, .right = right_ptr } };
        }
        return expr;
    }

    fn parse_logical_and(self: *Self) ParseError!ast.Node {
        var expr = try self.parse_cmp();

        while (self.match(.And)) {
            const operator = self.previous.tag;

            const right = try self.parse_cmp();

            const left_ptr = try self.arena.create(ast.Node);
            left_ptr.* = expr;

            const right_ptr = try self.arena.create(ast.Node);
            right_ptr.* = right;

            expr = .{ .Binary = .{ .left = left_ptr, .operator = operator, .right = right_ptr } };
        }
        return expr;
    }

    fn parse_cmp(self: *Self) ParseError!ast.Node {
        var expr = try self.parse_term();

        while (self.match(.EqualsEquals) or self.match(.BangEquals) or
            self.match(.Less) or self.match(.LessEqual) or
            self.match(.Greater) or self.match(.GreaterEqual))
        {
            const operator = self.previous.tag;
            const right = try self.parse_term();

            const left_ptr = try self.arena.create(ast.Node);
            left_ptr.* = expr;

            const right_ptr = try self.arena.create(ast.Node);
            right_ptr.* = right;

            expr = .{ .Binary = .{ .left = left_ptr, .operator = operator, .right = right_ptr } };
        }

        return expr;
    }

    fn parse_factor(self: *Self) ParseError!ast.Node {
        var expr = try self.parse_primary();

        while (self.match(.Star) or self.match(.Slash)) {
            const operator = self.previous.tag;
            const right = try self.parse_primary();

            const left_ptr = try self.arena.create(ast.Node);
            left_ptr.* = expr;

            const right_ptr = try self.arena.create(ast.Node);
            right_ptr.* = right;

            expr = .{ .Binary = .{ .left = left_ptr, .operator = operator, .right = right_ptr } };
        }
        return expr;
    }

    fn parse_term(self: *Self) ParseError!ast.Node {
        var expr = try self.parse_factor();

        while (self.match(.Plus) or self.match(.Minus)) {
            const operator = self.previous.tag;
            const right = try self.parse_factor();

            const left_ptr = try self.arena.create(ast.Node);
            left_ptr.* = expr;

            const right_ptr = try self.arena.create(ast.Node);
            right_ptr.* = right;
            expr = .{ .Binary = .{ .left = left_ptr, .operator = operator, .right = right_ptr } };
        }

        return expr;
    }

    fn parse_expr(self: *Self) ParseError!ast.Node {
        return self.parse_logical_or();
    }

    pub fn parse(self: *Self) !ast.Node {
        self.advance();

        var statement: std.ArrayList(ast.Node) = .empty;
        errdefer statement.deinit(self.arena);

        while (self.current.tag != .Eof) {
            if (self.match(.NewLine)) continue;

            const decl = try self.pase_decl();
            try statement.append(self.arena, decl);
        }

        return .{ .Root = .{ .statements = try statement.toOwnedSlice(self.arena) } };
    }
};
