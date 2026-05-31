const std = @import("std");
const ast = @import("ast.zig");
const stdlib = @import("../stdlib/stdlib.zig");

const chunk_mod = @import("chunk.zig");
const Opcode = chunk_mod.OpCode;
const Chunk = chunk_mod.Chunk;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const FunctionObj = value_mod.FunctionObj;
const ObjString = value_mod.ObjString;

pub const Local = struct {
    name: []const u8,
    depth: usize,
    is_mut: bool,
};

pub const Compiler = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    current_chunk: *Chunk,

    locals: [256]Local,
    local_count: usize,
    scope_depth: usize,

    known_globals: std.StringHashMap(bool),
    types_registry: std.StringHashMap([]const ast.Variant),

    pub fn init(allocator: std.mem.Allocator, chunk: *Chunk) Compiler {
        var comp = Compiler{
            .allocator = allocator,
            .current_chunk = chunk,
            .locals = undefined,
            .local_count = 0,
            .scope_depth = 0,
            .known_globals = std.StringHashMap(bool).init(allocator),
            .types_registry = std.StringHashMap([]const ast.Variant).init(allocator),
        };

        comp.locals[0] = .{
            .name = "",
            .depth = 0,
            .is_mut = false,
        };
        comp.local_count = 1;

        return comp;
    }

    fn deinit(self: *Self) void {
        self.known_globals.deinit();
        self.types_registry.deinit();
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

    fn emitLoop(self: *Compiler, loop_start: usize) !void {
        try self.emitOp(.OP_LOOP);
        const jump = self.current_chunk.code.items.len - loop_start + 2;
        if (jump > std.math.maxInt(u16)) {
            std.debug.print("Error: code block to large.\n", .{});
            return;
        }

        try self.emitByte(@intCast((jump >> 8) & 0xff));
        try self.emitByte(@intCast(jump & 0xff));
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

    fn compileVariable(self: *Compiler, name: []const u8, initializer: ast.Node, is_mut: bool) !void {
        try self.compile(initializer);

        if (self.scope_depth > 0) {
            self.locals[self.local_count] = .{
                .name = name,
                .depth = self.scope_depth,
                .is_mut = is_mut,
            };
            self.local_count += 1;
        } else {
            // C'est une globale
            try self.known_globals.put(name, is_mut);
            const name_index = try self.emitStringConstant(name);
            try self.emitOp(.OP_DEFINE_GLOBAL);
            try self.emitByte(name_index);
        }
    }

    fn compileFunctionBody(self: *Self, fn_decl: anytype) !void {
        const is_lambda = !@hasField(@TypeOf(fn_decl), "name");

        const name_obj = try self.allocator.create(ObjString);
        name_obj.* = .{
            .obj = .{ .obj_type = .String, .next = null },
            .chars = if (is_lambda) "<lambda>" else fn_decl.name,
        };

        var func_obj = try self.allocator.create(FunctionObj);
        func_obj.* = .{
            .obj = .{ .obj_type = .Function, .next = null },
            .arity = fn_decl.params.len,
            .chunk = Chunk.init(self.allocator),
            .name = name_obj,
        };

        var fn_comp = Compiler.init(self.allocator, &func_obj.chunk);

        fn_comp.locals[0] = .{ .name = "", .depth = 0, .is_mut = false };
        fn_comp.local_count = 1;
        fn_comp.scope_depth = 1;

        for (fn_decl.params) |param| {
            fn_comp.locals[fn_comp.local_count] = .{
                .name = param,
                .depth = 1,
                .is_mut = true,
            };
            fn_comp.local_count += 1;
        }

        try fn_comp.compile(fn_decl.body.*);

        if (is_lambda) {
            try fn_comp.emitOp(.OP_RETURN);
        } else {
            const zero_idx = try fn_comp.current_chunk.addConstant(.{ .Number = 0 });
            try fn_comp.emitOp(.OP_CONSTANT);
            try fn_comp.emitByte(zero_idx);
            try fn_comp.emitOp(.OP_RETURN);
        }

        const func_idx = try self.current_chunk.addConstant(.{ .Object = &func_obj.obj });
        try self.emitOp(.OP_CONSTANT);
        try self.emitByte(func_idx);
    }

    pub fn compile(self: *Compiler, node: ast.Node) anyerror!void {
        switch (node) {
            .Number => |n| {
                try self.emitConstant(.{ .Number = n });
            },
            .Boolean => |b| {
                try self.emitConstant(.{ .Boolean = b });
            },
            .Table => |table_node| {
                var array_count: usize = 0;
                var dict_count: usize = table_node.fields.len;

                for (table_node.elements) |elem| {
                    if (elem == .FnDeclaration) {
                        const key_idx = try self.emitStringConstant(elem.FnDeclaration.name);
                        try self.emitOp(.OP_CONSTANT);
                        try self.emitByte(key_idx);

                        try self.compileFunctionBody(elem.FnDeclaration);
                        dict_count += 1;
                    } else {
                        try self.compile(elem);
                        array_count += 1;
                    }
                }

                for (table_node.fields) |field| {
                    const key_idx = try self.emitStringConstant(field.key);
                    try self.emitOp(.OP_CONSTANT);
                    try self.emitByte(key_idx);

                    try self.compile(field.value);
                }

                try self.emitOp(.OP_BUILD_TABLE);
                try self.emitByte(@intCast(array_count));
                try self.emitByte(@intCast(dict_count));
            },
            .VariantAccess => |v| {
                if (self.types_registry.get(v.namespace)) |variants| {
                    var found = false;

                    for (variants) |variant| {
                        if (std.mem.eql(u8, variant.name, v.variant)) {
                            if (variant.params.len != 0) {
                                std.debug.print("Compile Error: Variant '{s}::{s}' expects {d} args but got 0.\n", .{ v.namespace, v.variant, variant.params.len });
                                return error.CompileError;
                            }
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        std.debug.print("Compile Error: Type '{s}' has no variant '{s}'.\n", .{ v.namespace, v.variant });
                        return error.CompileError;
                    }
                } else {
                    std.debug.print("Compile Error: Undefined type '{s}'.\n", .{v.namespace});
                    return error.CompileError;
                }

                const ns_idx = try self.emitStringConstant(v.namespace);
                const name_idx = try self.emitStringConstant(v.variant);

                try self.emitOp(.OP_BUILD_VARIANT);
                try self.emitByte(ns_idx);
                try self.emitByte(name_idx);
                try self.emitByte(0);
            },
            .VariantCall => |v| {
                if (self.types_registry.get(v.namespace)) |variants| {
                    var found = false;
                    for (variants) |variant| {
                        if (std.mem.eql(u8, variant.name, v.variant)) {
                            if (variant.params.len != v.arguments.len) {
                                std.debug.print("Compile Error: Variant '{s}::{s}' expects {d} arguments but got {d}.\n", .{ v.namespace, v.variant, variant.params.len, v.arguments.len });
                                return error.CompileError;
                            }
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        std.debug.print("Compile Error: Type '{s}' has no variant '{s}'.\n", .{ v.namespace, v.variant });
                        return error.CompileError;
                    }

                    for (v.arguments) |arg| {
                        try self.compile(arg);
                    }

                    const ns_idx = try self.emitStringConstant(v.namespace);
                    const name_idx = try self.emitStringConstant(v.variant);

                    try self.emitOp(.OP_BUILD_VARIANT);
                    try self.emitByte(ns_idx);
                    try self.emitByte(name_idx);
                    try self.emitByte(@intCast(v.arguments.len));
                } else {
                    const ns_idx = try self.emitStringConstant(v.namespace);
                    try self.emitOp(.OP_GET_GLOBAL);
                    try self.emitByte(ns_idx);

                    const func_idx = try self.emitStringConstant(v.variant);
                    try self.emitOp(.OP_GET_PROPERTY);
                    try self.emitByte(func_idx);

                    for (v.arguments) |arg| {
                        try self.compile(arg);
                    }

                    try self.emitOp(.OP_CALL);
                    try self.emitByte(@intCast(v.arguments.len));
                }
            },
            .String => |s| {
                const str_idx = try self.emitStringConstant(s);
                try self.emitOp(.OP_CONSTANT);
                try self.emitByte(str_idx);
            },
            .Binary => |b| {
                try self.compile(b.left.*);
                try self.compile(b.right.*);

                switch (b.operator) {
                    .Plus => try self.emitOp(.OP_ADD),
                    .Minus => try self.emitOp(.OP_SUBTRACT),
                    .Star => try self.emitOp(.OP_MULTIPLY),
                    .Slash => try self.emitOp(.OP_DIVIDE),
                    .EqualsEquals => try self.emitOp(.OP_EQUAL),
                    .Less => try self.emitOp(.OP_LESS),
                    else => {
                        std.debug.print("Unsupported operator : {s}\n", .{@tagName(b.operator)});
                        return error.UnsupportedOperator;
                    },
                }
            },
            .Get => |g| {
                try self.compile(g.object.*);

                const name_idx = try self.emitStringConstant(g.name);

                try self.emitOp(.OP_GET_PROPERTY);
                try self.emitByte(name_idx);
            },
            .LetDeclaration => |decl| {
                try self.compileVariable(decl.name, decl.initializer.*, false);
            },
            .MutDeclaration => |decl| {
                try self.compileVariable(decl.name, decl.initializer.*, true);
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
            .Set => |s| {
                try self.compile(s.object.*);
                try self.compile(s.value.*);

                const name_idx = try self.emitStringConstant(s.name);
                try self.emitOp(.OP_SET_PROPRETY);
                try self.emitByte(name_idx);
            },
            .MatchExpression => |m| {
                try self.compile(m.target.*);

                self.beginScope();
                self.locals[self.local_count] = .{ .name = "", .depth = self.scope_depth, .is_mut = false };
                self.local_count += 1;

                var end_jumps: std.ArrayList(usize) = .empty;

                for (m.branches) |branch| {
                    const ns_idx = if (branch.pattern.namespace) |ns| try self.emitStringConstant(ns) else 0;
                    const name_idx = try self.emitStringConstant(branch.pattern.name);
                    const has_ns: u8 = if (branch.pattern.namespace != null) 1 else 0;

                    try self.emitOp(.OP_MATCH_TEST);
                    try self.emitByte(has_ns);
                    try self.emitByte(ns_idx);
                    try self.emitByte(name_idx);
                    try self.emitByte(@intCast(branch.pattern.bindings.len));

                    const next_branch_jump = try self.emitJump(.OP_JUMP_IF_FALSE);
                    try self.emitOp(.OP_POP);

                    try self.emitOp(.OP_MATCH_BIND);
                    try self.emitByte(@intCast(branch.pattern.bindings.len));

                    self.beginScope();
                    for (branch.pattern.bindings) |binding_name| {
                        self.locals[self.local_count] = .{
                            .name = binding_name,
                            .depth = self.scope_depth,
                            .is_mut = false,
                        };
                        self.local_count += 1;
                    }

                    try self.compile(branch.body);

                    try self.endScope();

                    try end_jumps.append(self.allocator, try self.emitJump(.OP_JUMP));

                    self.patchJump(next_branch_jump);
                    try self.emitOp(.OP_POP);
                }

                try self.endScope();

                for (end_jumps.items) |jump| {
                    self.patchJump(jump);
                }
            },
            .WhileStatement => |while_stmt| {
                const loop_start = self.current_chunk.code.items.len;
                try self.compile(while_stmt.condition.*);

                const exit_jump = try self.emitJump(.OP_JUMP_IF_FALSE);
                try self.emitOp(.OP_POP);

                try self.compile(while_stmt.body.*);
                try self.emitLoop(loop_start);
                self.patchJump(exit_jump);
                try self.emitOp(.OP_POP);
            },
            .Assignment => |assign| {
                if (self.resolveLocal(assign.name)) |local_index| {
                    if (!self.locals[local_index].is_mut) {
                        std.debug.print("Error: you cannot mutate a constant variable: '{s}'.\n", .{assign.name});
                        return error.CompileError;
                    }
                    try self.compile(assign.value.*);
                    try self.emitOp(.OP_SET_LOCAL);
                    try self.emitByte(local_index);
                    try self.emitOp(.OP_POP);
                } else if (self.known_globals.get(assign.name)) |is_mut| {
                    if (!is_mut) {
                        std.debug.print("Error: you cannot mutate a constant variable: '{s}'.\n", .{assign.name});
                        return error.CompileError;
                    }
                    try self.compile(assign.value.*);
                    const name_index = try self.emitStringConstant(assign.name);
                    try self.emitOp(.OP_SET_GLOBAL);
                    try self.emitByte(name_index);
                    try self.emitOp(.OP_POP);
                } else {
                    std.debug.print("Error: unknown variable '{s}'\n", .{assign.name});
                    return error.CompileError;
                }
            },
            .TypeDeclaration => |*t| {
                try self.types_registry.put(t.name, t.variants);
            },
            .Root => |root| {
                for (root.statements) |stmt| {
                    try self.compile(stmt);
                }
            },
            .FnDeclaration => |fn_decl| {
                try self.compileFunctionBody(fn_decl);

                try self.known_globals.put(fn_decl.name, false);
                const name_idx = try self.emitStringConstant(fn_decl.name);
                try self.emitOp(.OP_DEFINE_GLOBAL);
                try self.emitByte(name_idx);
            },
            .Lambda => |lm| {
                try self.compileFunctionBody(lm);
            },
            .ReturnStatement => |ret| {
                if (ret.value) |val| {
                    try self.compile(val.*);
                } else {
                    //INFO:  return 0 by default
                    const zero_idx = try self.current_chunk.addConstant(.{ .Number = 0 });
                    try self.emitOp(.OP_CONSTANT);
                    try self.emitByte(zero_idx);
                }
                try self.emitOp(.OP_RETURN);
            },
            .MethodCall => |call| {
                try self.compile(call.object.*);

                for (call.arguments) |arg| {
                    try self.compile(arg);
                }

                const name_idx = try self.emitStringConstant(call.method);
                try self.emitOp(.OP_INVOKE);
                try self.emitByte(name_idx);
                try self.emitByte(@intCast(call.arguments.len));
            },
            .Call => |call| {
                try self.compile(call.callee.*);

                for (call.arguments) |arg| {
                    try self.compile(arg);
                }

                try self.emitOp(.OP_CALL);
                try self.emitByte(@intCast(call.arguments.len));
            },
            .Index => |idx| {
                try self.compile(idx.object.*);
                try self.compile(idx.index.*);

                try self.emitOp(.OP_GET_INDEX);
            },
        }
    }
};
