const std = @import("std");
const lexer = @import("lexer.zig");

pub const Node = union(enum) {
    Number: i64,
    String: []const u8,
    Identifier: []const u8,
    Boolean: bool,

    Root: struct {
        statements: []Node,
    },

    Assignment: struct {
        name: []const u8,
        value: *Node,
    },

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

    pub fn dump(self: Node, indent: usize, is_last: bool, depth_mask: u64) void {
        if (indent > 0) {
            var i: usize = 0;
            while (i < indent - 1) : (i += 1) {
                if ((depth_mask & (@as(u64, 1) << @intCast(i))) != 0) {
                    std.debug.print("│   ", .{});
                } else {
                    std.debug.print("    ", .{});
                }
            }

            if (is_last) {
                std.debug.print("└── ", .{});
            } else {
                std.debug.print("├── ", .{});
            }
        }

        var child_mask = depth_mask;
        if (indent > 0) {
            if (!is_last) {
                child_mask |= (@as(u64, 1) << @intCast(indent - 1));
            } else {
                child_mask &= ~(@as(u64, 1) << @intCast(indent - 1));
            }
        }

        switch (self) {
            .Root => |root| {
                std.debug.print("[Root]\n", .{});
                const len = root.statements.len;
                for (root.statements, 0..) |stmt, i| {
                    stmt.dump(indent + 1, i == len - 1, child_mask);
                }
            },
            .LetDeclaration => |decl| {
                std.debug.print("[Let: {s}]\n", .{decl.name});
                decl.initializer.dump(indent + 1, true, child_mask);
            },
            .MutDeclaration => |decl| {
                std.debug.print("[Mut: {s}]\n", .{decl.name});
                decl.initializer.dump(indent + 1, true, child_mask);
            },
            .Binary => |bin| {
                std.debug.print("[Binary: {s}]\n", .{@tagName(bin.operator)});
                bin.left.dump(indent + 1, false, child_mask);
                bin.right.dump(indent + 1, true, child_mask);
            },
            .Number => |n| {
                std.debug.print("Number({d})\n", .{n});
            },
            .String => |s| {
                std.debug.print("String({s})\n", .{s});
            },
            .Identifier => |id| {
                std.debug.print("Identifier({s})\n", .{id});
            },
            .Boolean => |b| {
                std.debug.print("Boolean({})\n", .{b});
            },
            .Assignment => |a| {
                std.debug.print("[Assign: {s}]\n", .{a.name});
                a.value.dump(indent + 1, true, child_mask);
            },
            else => std.debug.print("[Unimplemented Node Printer]\n", .{}),
        }
    }
};
