const std = @import("std");
const lexer = @import("lexer.zig");

pub const TableField = struct {
    key: []const u8,
    value: Node,
};

pub const Variant = struct {
    name: []const u8,
    params: []const []const u8,
};

pub const MatchPattern = struct {
    namespace: ?[]const u8,
    name: []const u8,
    bindings: []const []const u8,
};

pub const MatchBranch = struct {
    pattern: MatchPattern,
    body: Node,
};

pub const Node = union(enum) {
    Number: i64,
    String: []const u8,
    Identifier: []const u8,
    Boolean: bool,
    ExpressionStatement: *Node,

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
        statements: []Node,
    },

    IfStatement: struct {
        condition: *Node,
        then_branch: *Node,
        else_branch: ?*Node,
    },

    WhileStatement: struct {
        condition: *Node,
        body: *Node,
    },

    FnDeclaration: struct {
        name: []const u8,
        params: []const []const u8,
        body: *Node,
    },

    ReturnStatement: struct {
        value: ?*Node,
    },

    Call: struct {
        callee: *Node,
        arguments: []const Node,
    },

    Try: *Node, // '?' operation for error propagation

    Get: struct {
        object: *Node,
        name: []const u8,
    },

    Table: struct {
        fields: []const TableField,
        elements: []const Node,
    },

    MethodCall: struct {
        object: *Node,
        method: []const u8,
        arguments: []const Node,
    },

    TypeDeclaration: struct {
        name: []const u8,
        variants: []const Variant,
    },

    VariantAccess: struct {
        namespace: []const u8,
        variant: []const u8,
    },

    VariantCall: struct {
        namespace: []const u8,
        variant: []const u8,
        arguments: []const Node,
    },

    MatchExpression: struct {
        target: *Node,
        branches: []const MatchBranch,
    },

    Lambda: struct {
        params: []const []const u8,
        body: *Node,
    },

    Set: struct {
        object: *Node,
        name: []const u8,
        value: *Node,
    },

    Index: struct {
        object: *Node,
        index: *Node,
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
            .Block => |block| {
                std.debug.print("[Block]\n", .{});
                const len = block.statements.len;
                for (block.statements, 0..) |stmt, i| {
                    stmt.dump(indent + 1, i == len - 1, child_mask);
                }
            },
            .IfStatement => |if_stmt| {
                std.debug.print("[If]\n", .{});
                if_stmt.condition.dump(indent + 1, false, child_mask);

                if (if_stmt.else_branch) |else_b| {
                    if_stmt.then_branch.dump(indent + 1, false, child_mask);
                    else_b.dump(indent + 1, true, child_mask);
                } else {
                    if_stmt.then_branch.dump(indent + 1, true, child_mask);
                }
            },
            .WhileStatement => |while_stmt| {
                std.debug.print("[While]\n", .{});
                while_stmt.condition.dump(indent + 1, false, child_mask);
                while_stmt.body.dump(indent + 1, true, child_mask);
            },
            .FnDeclaration => |func| {
                std.debug.print("[Fn: {s}] (", .{func.name});
                for (func.params, 0..) |param, idx| {
                    if (idx > 0) std.debug.print(", ", .{});
                    std.debug.print("{s}", .{param});
                }
                std.debug.print(")\n", .{});
                func.body.dump(indent + 1, true, child_mask);
            },
            .ReturnStatement => |ret| {
                std.debug.print("[Return]\n", .{});
                if (ret.value) |val| {
                    val.dump(indent + 1, true, child_mask);
                }
            },
            .Call => |call| {
                std.debug.print("[Call]\n", .{});
                call.callee.dump(indent + 1, false, child_mask);
                const len = call.arguments.len;
                for (call.arguments, 0..) |arg, idx| {
                    arg.dump(indent + 1, idx == len - 1, child_mask);
                }
            },
            .Get => |get| {
                std.debug.print("[Get: {s}]\n", .{get.name});
                get.object.dump(indent + 1, true, child_mask);
            },
            .Table => |table| {
                std.debug.print("[Table]\n", .{});
                for (table.fields) |field| {
                    var i: u32 = 0;
                    while (i < indent + 1) : (i += 1) std.debug.print("│   ", .{});
                    std.debug.print("├── {s}:\n", .{field.key});
                    field.value.dump(indent + 2, false, child_mask);
                }
                const total_elems = table.elements.len;
                for (table.elements, 0..) |elem, idx| {
                    elem.dump(indent + 1, idx == total_elems - 1, child_mask);
                }
            },
            .MethodCall => |mcall| {
                std.debug.print("[MethodCall: {s}]\n", .{mcall.method});
                mcall.object.dump(indent + 1, false, child_mask);

                const len = mcall.arguments.len;
                for (mcall.arguments, 0..) |arg, idx| {
                    arg.dump(indent + 1, idx == len - 1, child_mask);
                }
            },
            .TypeDeclaration => |type_decl| {
                std.debug.print("[Type: {s}]\n", .{type_decl.name});
                const total_variants = type_decl.variants.len;
                for (type_decl.variants, 0..) |variant, idx| {
                    var i: u32 = 0;
                    while (i < indent + 1) : (i += 1) std.debug.print("│   ", .{});

                    if (idx == total_variants - 1) {
                        std.debug.print("└── | {s}", .{variant.name});
                    } else {
                        std.debug.print("├── | {s}", .{variant.name});
                    }

                    if (variant.params.len > 0) {
                        std.debug.print(" (", .{});
                        for (variant.params, 0..) |param, p_idx| {
                            if (p_idx > 0) std.debug.print(", ", .{});
                            std.debug.print("{s}", .{param});
                        }
                        std.debug.print(")", .{});
                    }
                    std.debug.print("\n", .{});
                }
            },
            .MatchExpression => |m| {
                std.debug.print("[Match]\n", .{});

                var j: u32 = 0;
                while (j < indent + 1) : (j += 1) std.debug.print("│   ", .{});
                std.debug.print("├── Target:\n", .{});
                m.target.dump(indent + 2, false, child_mask);

                const total_branches = m.branches.len;
                for (m.branches, 0..) |branch, idx| {
                    var i: u32 = 0;
                    while (i < indent + 1) : (i += 1) std.debug.print("│   ", .{});

                    if (idx == total_branches - 1) {
                        std.debug.print("└── => ", .{});
                    } else {
                        std.debug.print("├── => ", .{});
                    }

                    if (branch.pattern.namespace) |ns| {
                        std.debug.print("{s}::", .{ns});
                    }
                    std.debug.print("{s}", .{branch.pattern.name});

                    if (branch.pattern.bindings.len > 0) {
                        std.debug.print(" (", .{});
                        for (branch.pattern.bindings, 0..) |bind, b_idx| {
                            if (b_idx > 0) std.debug.print(", ", .{});
                            std.debug.print("{s}", .{bind});
                        }
                        std.debug.print(")", .{});
                    }
                    std.debug.print(":\n", .{});

                    branch.body.dump(indent + 2, idx == total_branches - 1, child_mask);
                }
            },
            .VariantAccess => |va| {
                std.debug.print("[VariantAccess: {s}::{s}]\n", .{ va.namespace, va.variant });
            },
            .VariantCall => |vc| {
                std.debug.print("[VariantCall: {s}::{s}]\n", .{ vc.namespace, vc.variant });
                const len = vc.arguments.len;
                for (vc.arguments, 0..) |arg, idx| {
                    arg.dump(indent + 1, idx == len - 1, child_mask);
                }
            },
            .Lambda => |lambda| {
                std.debug.print("[Lambda] |", .{});
                for (lambda.params, 0..) |param, p_idx| {
                    if (p_idx > 0) std.debug.print(", ", .{});
                    std.debug.print("{s}", .{param});
                }
                std.debug.print("|\n", .{});
                lambda.body.dump(indent + 1, true, child_mask);
            },
            else => {
                std.debug.print("[{}]", @tagName(self));
            },
        }
    }
};
