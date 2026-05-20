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

    fn parse_block(self: *Self) ParseError!ast.Node {
        try self.consume(.Indent, "Expected indentation to start a block.");

        var statements: std.ArrayList(ast.Node) = .empty;

        while (self.current.tag != .Dedent and self.current.tag != .Eof) {
            if (self.match(.NewLine)) continue;

            const stmt = try self.parse_decl();
            try statements.append(self.arena, stmt);
        }

        try self.consume(.Dedent, "Expected dedentation to close the block.");

        return .{ .Block = .{ .statements = try statements.toOwnedSlice(self.arena) } };
    }

    fn parse_while(self: *Self) ParseError!ast.Node {
        const condition_node = try self.parse_expr();
        const heap_condition = try self.arena.create(ast.Node);
        heap_condition.* = condition_node;

        try self.consume(.Colon, "Expected ':' after while condition");
        try self.consume(.NewLine, "Expected newline after ':' to start the block.");

        const body = try self.parse_block();
        const heap_body = try self.arena.create(ast.Node);
        heap_body.* = body;

        return .{ .WhileStatement = .{ .condition = heap_condition, .body = heap_body } };
    }

    fn parse_if(self: *Self) ParseError!ast.Node {
        const condition_node = try self.parse_expr();
        const heap_condition = try self.arena.create(ast.Node);
        heap_condition.* = condition_node;

        try self.consume(.Colon, "Expected ':' after if condition");
        try self.consume(.NewLine, "Expected newline after ':' to start the block.");

        const then_node = try self.parse_block();
        const heap_then = try self.arena.create(ast.Node);
        heap_then.* = then_node;

        var heap_else: ?*ast.Node = null;
        if (self.match(.Else)) {
            var else_node: ast.Node = undefined;

            if (self.match(.If)) {
                else_node = try self.parse_if();
            } else {
                try self.consume(.Colon, "Expected ':' after else.");
                try self.consume(.NewLine, "Expected newline after else.");
                else_node = try self.parse_block();
            }

            const raw_ptr = try self.arena.create(ast.Node);
            raw_ptr.* = else_node;
            heap_else = raw_ptr;
        }
        return .{ .IfStatement = .{
            .condition = heap_condition,
            .then_branch = heap_then,
            .else_branch = heap_else,
        } };
    }

    fn parse_fn(self: *Self) ParseError!ast.Node {
        try self.consume(.Identifier, "Expected function name after 'fn' keyword.");
        const name = self.previous.lexeme;

        try self.consume(.LParen, "Expected '(' after function name.");

        var params: std.ArrayList([]const u8) = .empty;

        if (self.current.tag != .RParen) {
            while (true) {
                try self.consume(.Identifier, "Expected parameter name.");
                try params.append(self.arena, self.previous.lexeme);

                if (!self.match(.Comma)) break;
            }
        }

        try self.consume(.RParen, "Expected ')' after parameters.");
        try self.consume(.Colon, "Expected ':' after function signature.");
        try self.consume(.NewLine, "Expected newline to start function body.");

        const body_node = try self.parse_block();
        const heap_body = try self.arena.create(ast.Node);
        heap_body.* = body_node;

        return .{ .FnDeclaration = .{
            .name = name,
            .params = try params.toOwnedSlice(self.arena),
            .body = heap_body,
        } };
    }

    fn parse_call(self: *Self) ParseError!ast.Node {
        var expr = try self.parse_primary();

        while (self.match(.LParen)) {
            var args: std.ArrayList(ast.Node) = .empty;

            if (self.current.tag != .RParen) {
                while (true) {
                    const arg = try self.parse_expr();
                    try args.append(self.arena, arg);

                    if (!self.match(.Comma)) break;
                }
            }

            try self.consume(.RParen, "Expected ')' after arguments.");

            const callee_ptr = try self.arena.create(ast.Node);
            callee_ptr.* = expr;

            expr = .{ .Call = .{
                .callee = callee_ptr,
                .arguments = try args.toOwnedSlice(self.arena),
            } };
        }

        return expr;
    }

    fn parse_decl(self: *Self) !ast.Node {
        if (self.match(.Fn)) {
            return self.parse_fn();
        }

        if (self.match(.If)) {
            return try self.parse_if();
        }

        if (self.match(.While)) {
            return try self.parse_while();
        }

        if (self.match(.Return)) {
            var heap_value: ?*ast.Node = null;

            if (self.current.tag != .NewLine and self.current.tag != .Eof) {
                const expr = try self.parse_expr();

                const raw_ptr = try self.arena.create(ast.Node);
                raw_ptr.* = expr;

                heap_value = raw_ptr;
            }
            try self.consume(.NewLine, "Expected newline after return statement");
            return .{ .ReturnStatement = .{ .value = heap_value } };
        }

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

        const expr = try self.parse_expr();

        if (self.match(.Equals)) {
            if (expr != .Identifier) {
                std.debug.print("Syntax error on line {d}: Invalid assignment target.\n", .{self.current.line});
                self.had_error = true;
                return error.SyntaxError;
            }

            const name = expr.Identifier;
            const value_node = try self.parse_expr();

            const heap_node = try self.arena.create(ast.Node);
            heap_node.* = value_node;

            if (self.current.tag != .Eof) {
                try self.consume(.NewLine, "Expected newline after assignment");
            }

            return .{ .Assignment = .{ .name = name, .value = heap_node } };
        }

        if (self.current.tag != .Eof) {
            try self.consume(.NewLine, "Expected newline after expression.");
        }

        return expr;
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
        var expr = try self.parse_call();

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

            const decl = try self.parse_decl();
            try statement.append(self.arena, decl);
        }

        return .{ .Root = .{ .statements = try statement.toOwnedSlice(self.arena) } };
    }
};
