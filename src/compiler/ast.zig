const std = @import("std");
const lexer = @import("lexer.zig");

pub const Node = union(enum) {
    Number: i64,
    String: []const u8,
    Identifier: []const u8,
    Boolean: bool,

    Binary: struct {
        left: *Node,
        operator: lexer.TokenType,
        right: *Node,
    },

    LetDeclaration: struct {
        name: []const u8,
        initializer: *Node,
    },
    MutDeclaration: struct {
        name: []const u8,
        initializer: *Node,
    },
    Block: struct {
        statement: []Node,
    },

    IfExpression: struct {
        conditiond: *Node,
        then_branch: *Node,
        else_branch: ?*Node,
    },
};
