const std = @import("std");

pub const TokenType = enum {
    // --- 1. Keywords ---
    Let, // let
    Mut, // mut
    Fn, // fn
    Type, // type
    Match, // match
    If, // if
    Else, // else
    While, // while
    Return, // return
    And, // and
    Or, // or

    // --- 2. Literals ---
    Identifier, // variable_name
    Number, // 42, 3.14
    String, // "hello"
    True, // true
    False, // false

    // --- 3. Symbols & Operators ---
    Colon, // :
    DoubleColon, // ::
    Comma, // ,
    Dot, // .
    Equals, // =
    EqualsEquals, // ==
    BangEquals, // !=
    Greater, // >
    GreaterEqual, // >=
    Less, // <
    LessEqual, // <=
    Plus, // +
    Minus, // -
    Star, // *
    Slash, // /
    Arrow, // => (for pattern matching)
    Pipe, // |  (for ADTs: | Some(val))
    Underscore, // _ (for pattern matching)

    Exclamationmark, // ! for error returning function
    QuestionMark, // ? for error propagation

    // --- 4. Delimiters ---
    LParen, // (
    RParen, // )
    LBrace, // {  (for Tables)
    RBrace, // }  (for Tables)
    LBracket, // ] (for indexation)
    RBracket,

    // --- 5. Formatting (LiLang's magic) ---
    Indent, // New indentation level (replaces '{')
    Dedent, // End of indentation level (replaces '}')
    NewLine, // End of line (replaces ';')

    // --- 6. Special ---
    Eof, // End Of File
    Error, // Syntax error (e.g., unknown character)
};

pub const Token = struct {
    tag: TokenType,
    lexeme: []const u8,
    line: usize,
};

pub const Lexer = struct {
    const Self = @This();

    source: []const u8,
    pos: usize,
    line: usize,

    is_line_start: bool,
    indent_stack: [32]usize,
    indent_depth: usize,
    pending_dedents: usize,

    pub fn init(source: []const u8) Self {
        var lexer = Self{
            .source = source,
            .pos = 0,
            .line = 1,
            .is_line_start = true,
            .indent_stack = undefined,
            .indent_depth = 1,
            .pending_dedents = 0,
        };
        lexer.indent_stack[0] = 0;
        return lexer;
    }

    fn makeToken(self: *Self, tag: TokenType, start: usize) Token {
        return .{
            .tag = tag,
            .lexeme = self.source[start..self.pos],
            .line = self.line,
        };
    }

    fn peek(self: *Self) ?u8 {
        if (self.pos >= self.source.len) return null;
        return self.source[self.pos];
    }

    fn peekNext(self: *Self) ?u8 {
        if (self.pos + 1 >= self.source.len) return null;
        return self.source[self.pos + 1];
    }

    fn advance(self: *Self) u8 {
        self.pos += 1;
        return self.source[self.pos - 1];
    }

    fn match(self: *Self, expected: u8) bool {
        if (self.peek()) |c| {
            if (c != expected) return false;
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn string(self: *Self, start: usize) Token {
        while (self.peek()) |ch| {
            if (ch == '"') break;
            if (ch == '\n') return self.makeToken(.Error, start);
            _ = self.advance();
        }

        if (self.peek() == '"') {
            const token = self.makeToken(.String, start + 1);
            _ = self.advance();
            return token;
        } else {
            return self.makeToken(.Error, start);
        }
    }

    fn number(self: *Self, start: usize) Token {
        while (self.peek()) |ch| {
            if (std.ascii.isDigit(ch)) {
                _ = self.advance();
            } else {
                break;
            }
        }

        // Look for a fractional part
        if (self.peek() == '.' and self.peekNext() != null and std.ascii.isDigit(self.peekNext().?)) {
            _ = self.advance(); // Consume the '.'
            while (self.peek()) |ch| {
                if (std.ascii.isDigit(ch)) {
                    _ = self.advance();
                } else {
                    break;
                }
            }
        }

        return self.makeToken(.Number, start);
    }

    fn identifier(self: *Self, start: usize) Token {
        while (self.peek()) |ch| {
            if (std.ascii.isAlphanumeric(ch) or ch == '_') {
                _ = self.advance();
            } else {
                break;
            }
        }

        const text = self.source[start..self.pos];

        if (std.mem.eql(u8, text, "_")) return self.makeToken(.Underscore, start);
        if (std.mem.eql(u8, text, "let")) return self.makeToken(.Let, start);
        if (std.mem.eql(u8, text, "mut")) return self.makeToken(.Mut, start);
        if (std.mem.eql(u8, text, "fn")) return self.makeToken(.Fn, start);
        if (std.mem.eql(u8, text, "type")) return self.makeToken(.Type, start);
        if (std.mem.eql(u8, text, "match")) return self.makeToken(.Match, start);
        if (std.mem.eql(u8, text, "if")) return self.makeToken(.If, start);
        if (std.mem.eql(u8, text, "else")) return self.makeToken(.Else, start);
        if (std.mem.eql(u8, text, "while")) return self.makeToken(.While, start);
        if (std.mem.eql(u8, text, "return")) return self.makeToken(.Return, start);
        if (std.mem.eql(u8, text, "and")) return self.makeToken(.And, start);
        if (std.mem.eql(u8, text, "or")) return self.makeToken(.Or, start);
        if (std.mem.eql(u8, text, "true")) return self.makeToken(.True, start);
        if (std.mem.eql(u8, text, "false")) return self.makeToken(.False, start);

        return self.makeToken(.Identifier, start);
    }

    pub fn next(self: *Self) Token {
        // 1. Flush pending dedents
        if (self.pending_dedents > 0) {
            self.pending_dedents -= 1;
            // self.indent_depth -= 1;
            return .{ .tag = .Dedent, .lexeme = "", .line = self.line };
        }

        if (self.is_line_start) {
            var spaces: usize = 0;
            while (self.peek()) |c| {
                if (c == ' ') {
                    spaces += 1;
                    _ = self.advance();
                } else {
                    break;
                }
            }

            if (self.peek() == '#') {
                while (self.peek()) |c| {
                    if (c == '\n') break;
                    _ = self.advance();
                }
                if (self.peek() == '\n') {
                    _ = self.advance();
                    self.line += 1;
                }
                self.is_line_start = true;
                return self.next();
            }

            const next_char = self.peek();
            if (next_char == '\n' or next_char == null) {
                // Do nothing
            } else {
                self.is_line_start = false;
                const current_indent = self.indent_stack[self.indent_depth - 1];

                if (spaces > current_indent) {
                    self.indent_stack[self.indent_depth] = spaces;
                    self.indent_depth += 1;
                    return .{ .tag = .Indent, .lexeme = "", .line = self.line };
                } else if (spaces < current_indent) {
                    while (self.indent_depth > 1 and spaces < self.indent_stack[self.indent_depth - 1]) {
                        self.pending_dedents += 1;
                        self.indent_depth -= 1;
                    }
                    self.pending_dedents -= 1;
                    return .{ .tag = .Dedent, .lexeme = "", .line = self.line };
                }
            }
        }

        while (self.peek()) |c| {
            if (c == ' ' or c == '\r' or c == '\t') {
                _ = self.advance();
            } else {
                break;
            }
        }

        if (self.peek() == null) {
            if (self.indent_depth > 1) {
                self.pending_dedents = self.indent_depth - 1;
                self.indent_depth = 1;
                self.pending_dedents -= 1;
                return .{ .tag = .Dedent, .lexeme = "", .line = self.line };
            }
            return .{ .tag = .Eof, .lexeme = "", .line = self.line };
        }

        const start = self.pos;
        const c = self.advance();

        if (c == '\n') {
            self.line += 1;
            self.is_line_start = true;
            return .{ .tag = .NewLine, .lexeme = "", .line = self.line };
        }

        if (c == '#') {
            while (self.peek()) |ch| {
                if (ch == '\n') break;
                _ = self.advance();
            }
            return self.next();
        }

        switch (c) {
            ':' => {
                if (self.match(':')) return self.makeToken(.DoubleColon, start);
                return self.makeToken(.Colon, start);
            },
            ',' => return self.makeToken(.Comma, start),
            '.' => return self.makeToken(.Dot, start),
            '(' => return self.makeToken(.LParen, start),
            ')' => return self.makeToken(.RParen, start),
            '{' => return self.makeToken(.LBrace, start),
            '}' => return self.makeToken(.RBrace, start),
            '[' => return self.makeToken(.LBracket, start),
            ']' => return self.makeToken(.RBracket, start),
            '+' => return self.makeToken(.Plus, start),
            '-' => return self.makeToken(.Minus, start),
            '*' => return self.makeToken(.Star, start),
            '/' => return self.makeToken(.Slash, start),
            '|' => return self.makeToken(.Pipe, start),
            '?' => return self.makeToken(.QuestionMark, start),

            '=' => {
                if (self.match('=')) return self.makeToken(.EqualsEquals, start);
                if (self.match('>')) return self.makeToken(.Arrow, start);
                return self.makeToken(.Equals, start);
            },
            '!' => {
                if (self.match('=')) return self.makeToken(.BangEquals, start) else return self.makeToken(.Exclamationmark, start);
            },
            '>' => {
                if (self.match('=')) return self.makeToken(.GreaterEqual, start);
                return self.makeToken(.Greater, start);
            },
            '<' => {
                if (self.match('=')) return self.makeToken(.LessEqual, start);
                return self.makeToken(.Less, start);
            },

            '"' => return self.string(start),

            else => {
                if (std.ascii.isDigit(c)) {
                    return self.number(start);
                } else if (std.ascii.isAlphabetic(c) or c == '_') {
                    return self.identifier(start);
                }
            },
        }

        return self.makeToken(.Error, start);
    }
};

const testing = std.testing;

const ExpectedToken = struct {
    tag: TokenType,
    lexeme: []const u8,
};

fn expectTokens(source: []const u8, expected: []const ExpectedToken) !void {
    var lexer = Lexer.init(source);
    for (expected) |exp| {
        const token = lexer.next();
        try testing.expectEqual(exp.tag, token.tag);
        try testing.expectEqualStrings(exp.lexeme, token.lexeme);
    }
    const eof = lexer.next();
    try testing.expectEqual(TokenType.Eof, eof.tag);
}

test "lexer: basic variable declaration" {
    const source = "let x = 42";
    try expectTokens(source, &.{
        .{ .tag = .Let, .lexeme = "let" },
        .{ .tag = .Identifier, .lexeme = "x" },
        .{ .tag = .Equals, .lexeme = "=" },
        .{ .tag = .Number, .lexeme = "42" },
    });
}

test "lexer: strings and floats" {
    const source =
        \\let msg = "hello"
        \\mut pi = 3.14
    ;
    try expectTokens(source, &.{
        .{ .tag = .Let, .lexeme = "let" },
        .{ .tag = .Identifier, .lexeme = "msg" },
        .{ .tag = .Equals, .lexeme = "=" },
        .{ .tag = .String, .lexeme = "hello" },
        .{ .tag = .NewLine, .lexeme = "" },
        .{ .tag = .Mut, .lexeme = "mut" },
        .{ .tag = .Identifier, .lexeme = "pi" },
        .{ .tag = .Equals, .lexeme = "=" },
        .{ .tag = .Number, .lexeme = "3.14" },
    });
}

test "lexer: python-like indentation and dedentation" {
    const source =
        \\fn test():
        \\    let a = 1
        \\    if a > 0:
        \\        return true
        \\let b = 2
    ;
    try expectTokens(source, &.{
        .{ .tag = .Fn, .lexeme = "fn" },
        .{ .tag = .Identifier, .lexeme = "test" },
        .{ .tag = .LParen, .lexeme = "(" },
        .{ .tag = .RParen, .lexeme = ")" },
        .{ .tag = .Colon, .lexeme = ":" },
        .{ .tag = .NewLine, .lexeme = "" },

        .{ .tag = .Indent, .lexeme = "" },
        .{ .tag = .Let, .lexeme = "let" },
        .{ .tag = .Identifier, .lexeme = "a" },
        .{ .tag = .Equals, .lexeme = "=" },
        .{ .tag = .Number, .lexeme = "1" },
        .{ .tag = .NewLine, .lexeme = "" },

        .{ .tag = .If, .lexeme = "if" },
        .{ .tag = .Identifier, .lexeme = "a" },
        .{ .tag = .Greater, .lexeme = ">" },
        .{ .tag = .Number, .lexeme = "0" },
        .{ .tag = .Colon, .lexeme = ":" },
        .{ .tag = .NewLine, .lexeme = "" },

        // Enter if block
        .{ .tag = .Indent, .lexeme = "" },
        .{ .tag = .Return, .lexeme = "return" },
        .{ .tag = .True, .lexeme = "true" },
        .{ .tag = .NewLine, .lexeme = "" },

        // Double dedent back to global scope!
        .{ .tag = .Dedent, .lexeme = "" },
        .{ .tag = .Dedent, .lexeme = "" },

        .{ .tag = .Let, .lexeme = "let" },
        .{ .tag = .Identifier, .lexeme = "b" },
        .{ .tag = .Equals, .lexeme = "=" },
        .{ .tag = .Number, .lexeme = "2" },
    });
}

test "lexer: comments are ignored" {
    const source =
        \\# This is a comment
        \\let x = 10 # Inline comment
        \\# Another comment
    ;
    try expectTokens(source, &.{
        // First comment is skipped, moves directly to let
        .{ .tag = .Let, .lexeme = "let" },
        .{ .tag = .Identifier, .lexeme = "x" },
        .{ .tag = .Equals, .lexeme = "=" },
        .{ .tag = .Number, .lexeme = "10" },
        .{ .tag = .NewLine, .lexeme = "" },
    });
}

test "lexer: match with default case" {
    const source =
        \\match oui:
        \\  Option::Some(v) => v
        \\  _ => oui
    ;

    try expectTokens(source, &.{
        .{ .tag = .Match, .lexeme = "match" },
        .{ .tag = .Identifier, .lexeme = "oui" },
        .{ .tag = .Colon, .lexeme = ":" },
        .{ .tag = .NewLine, .lexeme = "" },

        .{ .tag = .Indent, .lexeme = "" },
        .{ .tag = .Identifier, .lexeme = "Option" },
        .{ .tag = .DoubleColon, .lexeme = "::" },
        .{ .tag = .Identifier, .lexeme = "Some" },
        .{ .tag = .LParen, .lexeme = "(" },
        .{ .tag = .Identifier, .lexeme = "v" },
        .{ .tag = .RParen, .lexeme = ")" },
        .{ .tag = .Arrow, .lexeme = "=>" },
        .{ .tag = .Identifier, .lexeme = "v" },
        .{ .tag = .NewLine, .lexeme = "" },

        .{ .tag = .Underscore, .lexeme = "_" },
        .{ .tag = .Arrow, .lexeme = "=>" },
        .{ .tag = .Identifier, .lexeme = "oui" },

        .{ .tag = .Dedent, .lexeme = "" },
        .{ .tag = .Eof, .lexeme = "" },
    });
}

test "lexer: variant call at EOF without newline" {
    const source = "io::print(test)";

    try expectTokens(source, &.{
        .{ .tag = .Identifier, .lexeme = "io" },
        .{ .tag = .DoubleColon, .lexeme = "::" },
        .{ .tag = .Identifier, .lexeme = "print" },
        .{ .tag = .LParen, .lexeme = "(" },
        .{ .tag = .Identifier, .lexeme = "test" },
        .{ .tag = .RParen, .lexeme = ")" },

        .{ .tag = .Eof, .lexeme = "" },
    });
}

test "lexer: multi-character operators" {
    const source = ">= <= == != =>";
    try expectTokens(source, &.{
        .{ .tag = .GreaterEqual, .lexeme = ">=" },
        .{ .tag = .LessEqual, .lexeme = "<=" },
        .{ .tag = .EqualsEquals, .lexeme = "==" },
        .{ .tag = .BangEquals, .lexeme = "!=" },
        .{ .tag = .Arrow, .lexeme = "=>" },
    });
}
