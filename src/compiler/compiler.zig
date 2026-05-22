const std = @import("std");
const ast = @import("ast.zig");
const chunk_mod = @import("chunk.zig");
const Opcode = chunk_mod.OpCode;
const Chunk = chunk_mod.Chunk;
const value_mod = @import("value.zig");
const Value = value_mod.Value;

pub const Local = struct {
    name: []const u8,
    depth: usize,
};

pub const Compiler = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    current_chunk: *Chunk,

    locals: [256]Local,
    local_count: usize,
    scope_depth: usize,

    pub fn init(allocator: std.mem.Allocator, chunk: *Chunk) Compiler {
        return .{
            .allocator = allocator,
            .current_chunk = chunk,
            .locals = undefined,
            .local_count = 0,
            .scope_depth = 0,
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

    fn emitJump(self: *Self, instruction: Opcode) !usize {
        try self.emitOp(instruction);
        try self.emitByte(0xff);
        try self.emitByte(0xff);
        return self.current_chunk.code.items.len - 2;
    }

    fn patchJump(self: *Self, offset: usize) void {
        const jump = self.current_chunk.code.items.len - offset - 2;

        if (jump > std.math.maxInt(u16)) {
            std.debug.print("Error: code block to large.\n", .{});
            return;
        }

        self.current_chunk.code.items[offset] = @intCast((jump >> 8) & 0xff);
        self.current_chunk.code.items[offset + 1] = @intCast(jump & 0xff);
    }

    fn beginScope(self: *Self) void {
        self.scope_depth += 1;
    }

    fn endScope(self: *Self) !void {
        self.scope_depth -= 1;

        while (self.local_count > 0 and self.locals[self.local_count - 1].depth > self.scope_depth) {
            try self.emitOp(.OP_POP);
            self.local_count -= 1;
        }
    }

    fn resolveLocal(self: *Self, name: []const u8) ?u8 {
        var i: usize = self.local_count;

        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.locals[i].name, name)) {
                return @intCast(i);
            }
        }
        return null;
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

                if (self.scope_depth > 0) {
                    self.locals[self.local_count] = .{
                        .name = let_decl.name,
                        .depth = self.scope_depth,
                    };
                    self.local_count += 1;
                } else {
                    const name_index = try self.emitStringConstant(let_decl.name);
                    try self.emitOp(.OP_DEFINE_GLOBAL);
                    try self.emitByte(name_index);
                }
            },
            .Identifier => |name| {
                if (self.resolveLocal(name)) |local_idx| {
                    try self.emitOp(.OP_GET_LOCAL);
                    try self.emitByte(local_idx);
                } else {
                    const name_index = try self.emitStringConstant(name);
                    try self.emitOp(.OP_GET_GLOBAL);
                    try self.emitByte(name_index);
                }
            },
            .Block => |block| {
                self.beginScope();
                for (block.statements) |stmt| {
                    try self.compile(stmt);
                }
                try self.endScope();
            },
            .IfStatement => |if_stmt| {
                try self.compile(if_stmt.condition.*);

                const then_jump = try self.emitJump(.OP_JUMP_IF_FALSE);
                try self.emitOp(.OP_POP);
                try self.compile(if_stmt.then_branch.*);

                const else_jump = try self.emitJump(.OP_JUMP);
                self.patchJump(then_jump);
                try self.emitOp(.OP_POP);

                if (if_stmt.else_branch) |else_branch| {
                    try self.compile(else_branch.*);
                }

                self.patchJump(else_jump);
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
