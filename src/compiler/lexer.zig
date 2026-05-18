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

    // --- 4. Delimiters ---
    LParen, // (
    RParen, // )
    LBrace, // {  (for Tables)
    RBrace, // }  (for Tables)

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

    pub fn next(self: *Self) Token {
        _ = self;
        return .{ .tag = .Eof, .lexeme = "", .line = 0 };
    }
};
