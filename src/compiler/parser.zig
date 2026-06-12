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

            std.debug.print("Paring Error: invalid token :'{s}'\n", .{self.current.lexeme});

            self.had_error = true;
        }
    }

    fn match(self: *Self, tag: lexer.TokenType) bool {
        if (self.current.tag != tag) return false;
        self.advance();
        return true;
    }

    fn check(self: *Self, tag: lexer.TokenType) bool {
        return self.current.tag == tag;
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

    fn parse_fn(self: *Self, can_fail: bool) ParseError!ast.Node {
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
            .can_fail = can_fail,
        } };
    }

    fn parse_call(self: *Self) ParseError!ast.Node {
        var expr = try self.parse_primary();

        while (true) {
            if (self.match(.LParen)) {
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
            } else if (self.match(.Dot)) {
                try self.consume(.Identifier, "Expected proprety name after '.'.");
                const name = self.previous.lexeme;

                if (self.match(.LParen)) {
                    var args: std.ArrayList(ast.Node) = .empty;
                    if (self.current.tag != .RParen) {
                        while (true) {
                            const arg = try self.parse_expr();
                            try args.append(self.arena, arg);
                            if (!self.match(.Comma)) break;
                        }
                    }
                    try self.consume(.RParen, "Expected ')' after methode arguments.");

                    const object_ptr = try self.arena.create(ast.Node);
                    object_ptr.* = expr;

                    expr = .{ .MethodCall = .{
                        .object = object_ptr,
                        .method = name,
                        .arguments = try args.toOwnedSlice(self.arena),
                    } };
                } else {
                    const object_ptr = try self.arena.create(ast.Node);
                    object_ptr.* = expr;

                    expr = .{ .Get = .{
                        .object = object_ptr,
                        .name = name,
                    } };
                }
            } else if (self.match(.DoubleColon)) {
                var path: std.ArrayList([]const u8) = .empty;

                if (expr == .Identifier) {
                    try path.append(self.arena, expr.Identifier);
                } else if (expr == .PathAccess) {
                    for (expr.PathAccess.path) |p| try path.append(self.arena, p);
                } else {
                    std.debug.print("Syntax error on line {d}: Expected identifier before '::'.\n", .{self.current.line});
                    self.had_error = true;
                    return error.SyntaxError;
                }

                try self.consume(.Identifier, "Expected name after '::'.");
                try path.append(self.arena, self.previous.lexeme);

                if (self.match(.LParen)) {
                    var args: std.ArrayList(ast.Node) = .empty;
                    if (self.current.tag != .RParen) {
                        while (true) {
                            const arg = try self.parse_expr();
                            try args.append(self.arena, arg);
                            if (!self.match(.Comma)) break;
                        }
                    }
                    try self.consume(.RParen, "Expected ')' after arguments.");

                    expr = .{ .PathCall = .{
                        .path = try path.toOwnedSlice(self.arena),
                        .arguments = try args.toOwnedSlice(self.arena),
                    } };
                } else {
                    expr = .{ .PathAccess = .{
                        .path = try path.toOwnedSlice(self.arena),
                    } };
                }
            } else if (self.match(.LBracket)) {
                const index_node = try self.parse_expr();

                try self.consume(.RBracket, "Expected ']' after index.");
                const object_ptr = try self.arena.create(ast.Node);
                object_ptr.* = expr;

                const index_ptr = try self.arena.create(ast.Node);
                index_ptr.* = index_node;

                expr = .{ .Index = .{
                    .object = object_ptr,
                    .index = index_ptr,
                } };
            } else if (self.match(.QuestionMark)) {
                const expr_ptr = try self.arena.create(ast.Node);
                expr_ptr.* = expr;
                expr = .{ .Try = expr_ptr };
            } else {
                break;
            }
        }

        return expr;
    }

    fn parse_lambda(self: *Self) ParseError!ast.Node {
        var params: std.ArrayList([]const u8) = .empty;

        if (self.current.tag != .Pipe) {
            while (true) {
                try self.consume(.Identifier, "Expected parameter name in lambda.");
                try params.append(self.arena, self.previous.lexeme);
                if (!self.match(.Comma)) break;
            }
        }

        try self.consume(.Pipe, "Expected '|' to close lambda parameters.");

        const body_node = try self.parse_expr();
        const heap_body = try self.arena.create(ast.Node);
        heap_body.* = body_node;

        return .{ .Lambda = .{
            .params = try params.toOwnedSlice(self.arena),
            .body = heap_body,
        } };
    }

    fn parse_match(self: *Self) ParseError!ast.Node {
        const target_node = try self.parse_expr();
        const target_ptr = try self.arena.create(ast.Node);
        target_ptr.* = target_node;

        try self.consume(.Colon, "Expected ':' after match target.");
        try self.consume(.NewLine, "Expected newline after match ':'.");

        try self.consume(.Indent, "Expected indentation for match branches.");
        var branches: std.ArrayList(ast.MatchBranch) = .empty;

        while (self.current.tag != .Dedent and self.current.tag != .Eof) {
            if (self.match(.NewLine)) continue;

            var pattern_namespace: ?[]const u8 = null;
            var pattern_name: []const u8 = undefined;
            var bindings: std.ArrayList([]const u8) = .empty;

            if (self.match(.Underscore)) {
                pattern_name = "_";
            } else {
                try self.consume(.Identifier, "Expected pattern identifiers in match branch.");
                pattern_name = self.previous.lexeme;
                if (self.match(.DoubleColon)) {
                    pattern_namespace = pattern_name;
                    try self.consume(.Identifier, "Expected variant name after '::'.");
                    pattern_name = self.previous.lexeme;
                }

                if (self.match(.LParen)) {
                    if (self.current.tag != .RParen) {
                        while (true) {
                            try self.consume(.Identifier, "Expected bindings identifiers in pattern.");
                            try bindings.append(self.arena, self.previous.lexeme);
                            if (!self.match(.Comma)) break;
                        }
                    }
                    try self.consume(.RParen, "Expected ')' after pattern bindings.");
                }
            }

            try self.consume(.Arrow, "Expected '=>' after match pattern.");
            var body_node: ast.Node = undefined;

            if (self.match(.NewLine)) {
                body_node = try self.parse_block();
            } else {
                body_node = try self.parse_expr();
                if (self.current.tag != .Dedent and self.current.tag != .Eof) {
                    try self.consume(.NewLine, "Expected newline after match branch expression.");
                }
            }

            try branches.append(self.arena, .{
                .pattern = .{
                    .namespace = pattern_namespace,
                    .name = pattern_name,
                    .bindings = try bindings.toOwnedSlice(self.arena),
                },
                .body = body_node,
            });
        }

        try self.consume(.Dedent, "Expected dedentation to close match block.");

        return .{ .MatchExpression = .{
            .target = target_ptr,
            .branches = try branches.toOwnedSlice(self.arena),
        } };
    }

    fn patse_type(self: *Self) ParseError!ast.Node {
        try self.consume(.Identifier, "Expected type name after 'type' keyword.");
        const type_name = self.previous.lexeme;

        try self.consume(.Equals, "Expected '=' after type name.");
        try self.consume(.NewLine, "Expected newline after '='in type declaration.");

        try self.consume(.Indent, "Expected indentation for type variants.");

        var variants: std.ArrayList(ast.Variant) = .empty;

        while (self.current.tag != .Dedent and self.current.tag != .Eof) {
            if (self.match(.NewLine)) continue;

            try self.consume(.Pipe, "Expected '|' to declare a vriant.");
            try self.consume(.Identifier, "Expected variant name after '|'.");
            const variant_name = self.previous.lexeme;

            var params: std.ArrayList([]const u8) = .empty;

            if (self.match(.LParen)) {
                if (self.current.tag != .RParen) {
                    while (true) {
                        try self.consume(.Identifier, "Expected parameter name in variant.");
                        try params.append(self.arena, self.previous.lexeme);
                        if (!self.match(.Comma)) break;
                    }
                }
                try self.consume(.RParen, "Expected ')' after variant parameters.");
            }
            try variants.append(self.arena, .{
                .name = variant_name,
                .params = try params.toOwnedSlice(self.arena),
            });

            if (self.current.tag != .Dedent) {
                try self.consume(.NewLine, "Expected a newline after variant declaration.");
            }
        }

        try self.consume(.Dedent, "Expected dedentation to close type declaration.");
        return .{ .TypeDeclaration = .{
            .name = type_name,
            .variants = try variants.toOwnedSlice(self.arena),
        } };
    }

    fn parse_table(self: *Self) !ast.Node {
        var fields: std.ArrayList(ast.TableField) = .empty;
        var elements: std.ArrayList(ast.Node) = .empty;
        var map_entries: std.ArrayList(ast.MapEntry) = .empty;

        var is_map = false;
        var is_first = true;
        if (self.current.tag != .RBrace) {
            while (true) {
                while (self.match(.NewLine) or self.match(.Indent) or self.match(.Dedent)) {}

                if (self.check(.RBrace)) break;

                const expr = try self.parse_expr();

                if (self.match(.Arrow)) {
                    if (is_first) is_map = true;

                    if (!is_map) {
                        std.debug.print("Syntax error on line {d}: Cannot mix table fields (:) and map entries (=>).\n", .{self.current.line});
                        self.had_error = true;
                        return error.SyntaxError;
                    }

                    const val = try self.parse_expr();
                    try map_entries.append(self.arena, .{ .key = expr, .value = val });
                } else if (self.match(.Colon)) {
                    if (is_first) is_map = false;

                    if (is_map) {
                        std.debug.print("Syntax error on line {d}: Cannot mix map entries (=>) and table fields (:).\n", .{self.current.line});
                        self.had_error = true;
                        return error.SyntaxError;
                    }

                    if (expr != .Identifier) {
                        std.debug.print("Syntax error on line {d}: Table keys must be identifiers.\n", .{self.current.line});
                        self.had_error = true;
                        return error.SyntaxError;
                    }

                    const key = expr.Identifier;

                    const val = try self.parse_expr();
                    try fields.append(self.arena, .{ .key = key, .value = val });
                } else {
                    if (is_first) is_map = false;

                    if (is_map) {
                        std.debug.print("Syntax error on line {d}: Cannot mix map entries and raw elements.\n", .{self.current.line});
                        self.had_error = true;
                        return error.SyntaxError;
                    }

                    try elements.append(self.arena, expr);
                }

                is_first = false;

                while (self.match(.NewLine) or self.match(.Indent) or self.match(.Dedent)) {}

                if (!self.match(.Comma)) break;
            }
        }

        while (self.match(.NewLine) or self.match(.Indent) or self.match(.Dedent)) {}
        try self.consume(.RBrace, "Expected '}' to close the table.");

        if (is_map) {
            return .{ .Map = .{
                .entries = try map_entries.toOwnedSlice(self.arena),
            } };
        } else {
            return .{ .Table = .{
                .fields = try fields.toOwnedSlice(self.arena),
                .elements = try elements.toOwnedSlice(self.arena),
            } };
        }
    }

    fn parse_decl(self: *Self) !ast.Node {
        if (self.match(.Type)) return try self.patse_type();
        if (self.match(.Fn)) {
            const can_fail = self.match(.Exclamationmark);
            return try self.parse_fn(can_fail);
        }
        if (self.match(.If)) {
            return try self.parse_if();
        }

        if (self.match(.While)) {
            return try self.parse_while();
        }

        if (self.match(.Return)) {
            const line = self.previous.line;
            var heap_value: ?*ast.Node = null;

            if (self.current.tag != .NewLine and self.current.tag != .Eof) {
                const expr = try self.parse_expr();

                const raw_ptr = try self.arena.create(ast.Node);
                raw_ptr.* = expr;

                heap_value = raw_ptr;
            }
            try self.consume(.NewLine, "Expected newline after return statement");
            return .{ .ReturnStatement = .{ .value = heap_value, .line = line } };
        }

        if (self.match(.Let)) {
            const line = self.previous.line;
            try self.consume(.Identifier, "Expected variable name after 'let'.");
            const name = self.previous.lexeme;

            try self.consume(.Equals, "Expected equal sign after a variable name in assignation.");

            const value_node = try self.parse_expr();

            const heap_node = try self.arena.create(ast.Node);
            heap_node.* = value_node;

            if (self.current.tag != .Eof) {
                try self.consume(.NewLine, "Expected newline after variable declaration.");
            }

            return .{ .LetDeclaration = .{ .name = name, .initializer = heap_node, .line = line } };
        }

        if (self.match(.Mut)) {
            const line = self.previous.line;
            try self.consume(.Identifier, "Expected variable name after 'let'.");
            const name = self.previous.lexeme;

            try self.consume(.Equals, "Expected equal sign after a variable name in assignation.");

            const value_node = try self.parse_expr();

            const heap_node = try self.arena.create(ast.Node);
            heap_node.* = value_node;

            if (self.current.tag != .Eof) {
                try self.consume(.NewLine, "Expected newline after variable declaration.");
            }

            return .{ .MutDeclaration = .{ .name = name, .initializer = heap_node, .line = line } };
        }

        const expr = try self.parse_expr();
        const line = self.previous.line;

        if (self.match(.Equals)) {
            // const name = expr.Identifier;
            const value_node = try self.parse_expr();

            const heap_node = try self.arena.create(ast.Node);
            heap_node.* = value_node;

            if (self.current.tag != .Eof) {
                try self.consume(.NewLine, "Expected newline after assignment");
            }

            switch (expr) {
                .Identifier => |name| {
                    return .{ .Assignment = .{ .name = name, .value = heap_node, .line = line } };
                },
                .Get => |g| {
                    return .{ .Set = .{ .object = g.object, .name = g.name, .value = heap_node, .line = line } };
                },
                .PathAccess => |pa| {
                    if (pa.path.len < 2) return error.SyntaxError;

                    var obj_node: ast.Node = undefined;
                    if (pa.path.len == 2) {
                        obj_node = .{ .Identifier = pa.path[0] };
                    } else {
                        obj_node = .{ .PathAccess = .{ .path = pa.path[0 .. pa.path.len - 1] } };
                    }

                    const obj_ptr = try self.arena.create(ast.Node);
                    obj_ptr.* = obj_node;

                    return .{ .Set = .{ .object = obj_ptr, .name = pa.path[pa.path.len - 1], .value = heap_node, .line = line } };
                },
                else => {
                    std.debug.print("Syntax error on line {d}: Invalid assignment target.\n", .{self.current.line});
                    self.had_error = true;
                    return error.SyntaxError;
                },
            }
        }

        if (self.current.tag != .Eof and self.current.tag != .Dedent and self.previous.tag != .Dedent) {
            try self.consume(.NewLine, "Expected newline after expression.");
        } else if (self.current.tag == .NewLine) {
            _ = self.advance();
        }

        const expr_ptr = try self.arena.create(ast.Node);
        expr_ptr.* = expr;

        return .{ .ExpressionStatement = .{ .expr = expr_ptr, .line = self.previous.line } };
    }

    fn parse_primary(self: *Self) ParseError!ast.Node {
        if (self.match(.Number)) return .{ .Number = try std.fmt.parseInt(i64, self.previous.lexeme, 10) };
        if (self.match(.String)) return .{ .String = self.previous.lexeme };
        if (self.match(.True) or self.match(.False)) return .{ .Boolean = self.previous.tag == .True };
        if (self.match(.Identifier)) return .{ .Identifier = self.previous.lexeme };
        if (self.match(.Null)) return .Null;

        if (self.match(.Match)) return try self.parse_match();

        if (self.match(.Pipe)) return try self.parse_lambda();
        if (self.match(.LBrace)) return try self.parse_table();

        if (self.match(.Import)) {
            try self.consume(.LParen, "Expected '(' after 'import'.");
            const path_node = try self.parse_expr();
            try self.consume(.RParen, "Expected ')' after 'import'.");

            const path_ptr = try self.arena.create(ast.Node);
            path_ptr.* = path_node;

            return .{ .Import = .{ .path = path_ptr } };
        }

        if (self.match(.Fn)) {
            const can_fail = self.match(.Exclamationmark);
            return try self.parse_fn(can_fail);
        }

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
            const right = try self.parse_call();

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

const testing = std.testing;

// --- Helper function to simplify test setup ---
fn setupParserTest(allocator: std.mem.Allocator, source: []const u8) !ast.Node {
    var scanner = lexer.Lexer.init(source);
    var prsr = Parser.init(&scanner, allocator);
    return prsr.parse();
}

test "parser: let and mut declarations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\let a = 10
        \\mut b = "hello"
    ;

    const root = try setupParserTest(arena.allocator(), source);
    const stmts = root.Root.statements;

    try testing.expectEqual(@as(usize, 2), stmts.len);

    // Test 'let a = 10'
    try testing.expectEqual(.LetDeclaration, std.meta.activeTag(stmts[0]));
    try testing.expectEqualStrings("a", stmts[0].LetDeclaration.name);
    try testing.expectEqual(.Number, std.meta.activeTag(stmts[0].LetDeclaration.initializer.*));
    try testing.expectEqual(@as(i64, 10), stmts[0].LetDeclaration.initializer.*.Number);

    // Test 'mut b = "hello"'
    try testing.expectEqual(.MutDeclaration, std.meta.activeTag(stmts[1]));
    try testing.expectEqualStrings("b", stmts[1].MutDeclaration.name);
    try testing.expectEqual(.String, std.meta.activeTag(stmts[1].MutDeclaration.initializer.*));
    try testing.expectEqualStrings("hello", stmts[1].MutDeclaration.initializer.*.String);
}

test "parser: operator precedence (math and logical)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // 1 + 2 * 3 should parse as 1 + (2 * 3)
    const source = "let x = 1 + 2 * 3 > 10 and true";

    const root = try setupParserTest(arena.allocator(), source);
    const stmt = root.Root.statements[0];

    try testing.expectEqual(.LetDeclaration, std.meta.activeTag(stmt));
    const expr = stmt.LetDeclaration.initializer.*;

    // Top level should be 'and'
    try testing.expectEqual(.Binary, std.meta.activeTag(expr));
    try testing.expectEqual(.And, expr.Binary.operator);

    // Left of 'and' should be '>'
    const cmp = expr.Binary.left.*;
    try testing.expectEqual(.Binary, std.meta.activeTag(cmp));
    try testing.expectEqual(.Greater, cmp.Binary.operator);

    // Left of '>' should be '+'
    const add = cmp.Binary.left.*;
    try testing.expectEqual(.Binary, std.meta.activeTag(add));
    try testing.expectEqual(.Plus, add.Binary.operator);

    // Right of '+' should be '*'
    const mul = add.Binary.right.*;
    try testing.expectEqual(.Binary, std.meta.activeTag(mul));
    try testing.expectEqual(.Star, mul.Binary.operator);
}

test "parser: function declaration and return" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\fn add(a, b):
        \\    return a + b
        \\
    ;

    const root = try setupParserTest(arena.allocator(), source);
    const stmts = root.Root.statements;

    try testing.expectEqual(@as(usize, 1), stmts.len);

    const func = stmts[0];
    try testing.expectEqual(.FnDeclaration, std.meta.activeTag(func));
    try testing.expectEqualStrings("add", func.FnDeclaration.name);

    const params = func.FnDeclaration.params;
    try testing.expectEqual(@as(usize, 2), params.len);
    try testing.expectEqualStrings("a", params[0]);
    try testing.expectEqualStrings("b", params[1]);

    const body = func.FnDeclaration.body.*;
    try testing.expectEqual(.Block, std.meta.activeTag(body));

    const ret = body.Block.statements[0];
    try testing.expectEqual(.ReturnStatement, std.meta.activeTag(ret));
    try testing.expectEqual(.Binary, std.meta.activeTag(ret.ReturnStatement.value.?.*));
}

test "parser: if / else block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\if x > 10:
        \\    let y = 1
        \\else:
        \\    let y = 2
        \\
    ;

    const root = try setupParserTest(arena.allocator(), source);
    const stmt = root.Root.statements[0];

    try testing.expectEqual(.IfStatement, std.meta.activeTag(stmt));
    const if_stmt = stmt.IfStatement;

    try testing.expectEqual(.Binary, std.meta.activeTag(if_stmt.condition.*));
    try testing.expectEqual(.Block, std.meta.activeTag(if_stmt.then_branch.*));
    try testing.expect(if_stmt.else_branch != null);
    try testing.expectEqual(.Block, std.meta.activeTag(if_stmt.else_branch.?.*));
}

test "parser: tables (records and arrays)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\let user = {
        \\    name: "imad",
        \\    age: 30,
        \\    42
        \\}
    ;

    const root = try setupParserTest(arena.allocator(), source);
    const table_expr = root.Root.statements[0].LetDeclaration.initializer.*;

    try testing.expectEqual(.Table, std.meta.activeTag(table_expr));
    const table = table_expr.Table;

    try testing.expectEqual(@as(usize, 2), table.fields.len);
    try testing.expectEqualStrings("name", table.fields[0].key);
    try testing.expectEqualStrings("age", table.fields[1].key);

    try testing.expectEqual(@as(usize, 1), table.elements.len);
    try testing.expectEqual(.Number, std.meta.activeTag(table.elements[0]));
    try testing.expectEqual(@as(i64, 42), table.elements[0].Number);
}

test "parser: algebraic data types (ADT)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\type Option =
        \\    | Some(value)
        \\    | None
    ;

    const root = try setupParserTest(arena.allocator(), source);
    const type_decl = root.Root.statements[0];

    try testing.expectEqual(.TypeDeclaration, std.meta.activeTag(type_decl));
    try testing.expectEqualStrings("Option", type_decl.TypeDeclaration.name);

    const variants = type_decl.TypeDeclaration.variants;
    try testing.expectEqual(@as(usize, 2), variants.len);

    try testing.expectEqualStrings("Some", variants[0].name);
    try testing.expectEqual(@as(usize, 1), variants[0].params.len);
    try testing.expectEqualStrings("value", variants[0].params[0]);

    try testing.expectEqualStrings("None", variants[1].name);
    try testing.expectEqual(@as(usize, 0), variants[1].params.len);
}

test "parser: pattern matching" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\let res = match opt:
        \\    Option::Some(v) => v * 2
        \\    Option::None => 0
    ;

    const root = try setupParserTest(arena.allocator(), source);
    const match_expr = root.Root.statements[0].LetDeclaration.initializer.*;

    try testing.expectEqual(.MatchExpression, std.meta.activeTag(match_expr));
    const m = match_expr.MatchExpression;

    try testing.expectEqual(.Identifier, std.meta.activeTag(m.target.*));
    try testing.expectEqual(@as(usize, 2), m.branches.len);

    // Test branch 1 (Option::Some(v))
    const b1 = m.branches[0];
    try testing.expectEqualStrings("Option", b1.pattern.namespace.?);
    try testing.expectEqualStrings("Some", b1.pattern.name);
    try testing.expectEqualStrings("v", b1.pattern.bindings[0]);
    try testing.expectEqual(.Binary, std.meta.activeTag(b1.body));

    // Test branch 2 (Option::None)
    const b2 = m.branches[1];
    try testing.expectEqualStrings("Option", b2.pattern.namespace.?);
    try testing.expectEqualStrings("None", b2.pattern.name);
    try testing.expectEqual(@as(usize, 0), b2.pattern.bindings.len);
    try testing.expectEqual(.Number, std.meta.activeTag(b2.body));
}

test "parser: pattern matching with default case" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\let res = match opt:
        \\    Option::Some(v) => v * 2
        \\    _ => 0
    ;

    const root = try setupParserTest(arena.allocator(), source);
    const match_expr = root.Root.statements[0].LetDeclaration.initializer.*;

    try testing.expectEqual(.MatchExpression, std.meta.activeTag(match_expr));
    const m = match_expr.MatchExpression;

    try testing.expectEqual(.Identifier, std.meta.activeTag(m.target.*));
    try testing.expectEqual(@as(usize, 2), m.branches.len);

    // Test branch 1 (Option::Some(v))
    const b1 = m.branches[0];
    try testing.expectEqualStrings("Option", b1.pattern.namespace.?);
    try testing.expectEqualStrings("Some", b1.pattern.name);
    try testing.expectEqualStrings("v", b1.pattern.bindings[0]);
    try testing.expectEqual(.Binary, std.meta.activeTag(b1.body));

    // Test branch 2 default '_'
    const b2 = m.branches[1];
    try testing.expectEqual(null, b2.pattern.namespace);
    try testing.expectEqualStrings("_", b2.pattern.name);
    try testing.expectEqual(@as(usize, 0), b2.pattern.bindings.len);
    try testing.expectEqual(.Number, std.meta.activeTag(b2.body));
}

test "parser: method calls and lambdas" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "let mapped = users.map(|u| u.age)";

    const root = try setupParserTest(arena.allocator(), source);
    const mcall = root.Root.statements[0].LetDeclaration.initializer.*;

    try testing.expectEqual(.MethodCall, std.meta.activeTag(mcall));
    try testing.expectEqualStrings("map", mcall.MethodCall.method);

    const args = mcall.MethodCall.arguments;
    try testing.expectEqual(@as(usize, 1), args.len);

    try testing.expectEqual(.Lambda, std.meta.activeTag(args[0]));
    const lambda = args[0].Lambda;
    try testing.expectEqualStrings("u", lambda.params[0]);
    try testing.expectEqual(.Get, std.meta.activeTag(lambda.body.*));
}

test "parser: variant call at EOF" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source = "io::print(test)";

    const root = try setupParserTest(arena.allocator(), source);

    const call_node = root.Root.statements[0].ExpressionStatement.expr.*;

    try std.testing.expectEqual(.PathCall, std.meta.activeTag(call_node));
    try std.testing.expectEqual(call_node.PathCall.path.len, 2);
    try std.testing.expectEqualStrings("io", call_node.PathCall.path[0]);
    try std.testing.expectEqualStrings("print", call_node.PathCall.path[1]);

    const args = call_node.PathCall.arguments;
    try std.testing.expectEqual(@as(usize, 1), args.len);

    try std.testing.expectEqual(.Identifier, std.meta.activeTag(args[0]));
    try std.testing.expectEqualStrings("test", args[0].Identifier);
}
