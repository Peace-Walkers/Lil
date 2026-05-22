const std = @import("std");
const ast = @import("ast.zig");
const chunk_mod = @import("chunk.zig");
const Opcode = chunk_mod.OpCode;
const Chunk = chunk_mod.Chunk;
const value_mod = @import("value.zig");
const Value = value_mod.Value;

pub const Compiler = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    current_chunk: *Chunk,

    pub fn init(allocator: std.mem.Allocator, chunk: *Chunk) Compiler {
        return .{
            .allocator = allocator,
            .current_chunk = chunk,
        };
    }

    fn emitByte(self: *Self, byte: u8) !void {
        try self.current_chunk.write(byte, 0);
    }

    fn emitOp(self: *Self, op: Opcode) !void {
        try self.emitByte(@intFromEnum(op));
    }

    fn emitConstant(self: *Compiler, val: Value) !void {
        const index = try self.current_chunk.addConstant(val);
        try self.emitOp(.OP_CONSTANT);
        try self.emitByte(index);
    }

    fn emitStringConstant(self: *Compiler, text: []const u8) !u8 {
        const obj_str = try self.allocator.create(value_mod.ObjString);
        obj_str.* = .{
            .obj = .{ .obj_type = .String, .next = null },
            .chars = text,
        };

        const val = Value{ .Object = &obj_str.obj };
        return try self.current_chunk.addConstant(val);
    }

    pub fn compile(self: *Compiler, node: ast.Node) anyerror!void {
        switch (node) {
            .Number => |n| {
                try self.emitConstant(.{ .Number = n });
            },
            .Binary => |b| {
                try self.compile(b.left.*);
                try self.compile(b.right.*);

                switch (b.operator) {
                    .Plus => try self.emitOp(.OP_ADD),
                    .Minus => try self.emitOp(.OP_SUBTRACT),
                    .Star => try self.emitOp(.OP_MULTIPLY),
                    .Slash => try self.emitOp(.OP_DIVIDE),
                    else => {
                        std.debug.print("Unsupported operator : {s}\n", .{@tagName(b.operator)});
                        return error.UnsupportedOperator;
                    },
                }
            },
            .LetDeclaration => |let_decl| {
                try self.compile(let_decl.initializer.*);
                const name_index = try self.emitStringConstant(let_decl.name);

                try self.emitOp(.OP_DEFINE_GLOBAL);
                try self.emitByte(name_index);
            },
            .Identifier => |name| {
                const name_index = try self.emitStringConstant(name);
                try self.emitOp(.OP_GET_GLOBAL);
                try self.emitByte(name_index);
            },
            .Root => |root| {
                for (root.statements) |stmt| {
                    try self.compile(stmt);
                }
            },
            else => {
                std.debug.print("Unsupported node: {s}\n", .{@tagName(node)});
            },
        }
    }
};
