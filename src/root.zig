const std = @import("std");
const lexer = @import("compiler/lexer.zig");
const parser = @import("compiler/parser.zig");
const chunk_mod = @import("compiler/chunk.zig");
const value_mod = @import("compiler/value.zig");
const compiler = @import("compiler/compiler.zig");
const debug = @import("compiler/debug.zig");
const VM = @import("runtime/vm.zig").VM;

pub const VmIo = @import("runtime/vm.zig").VmIo;

pub fn interpret(io: VmIo, allocator: std.mem.Allocator, source: []const u8) !void {
    var vm = try VM.init(allocator, io);
    defer vm.deinit();

    var scanner = lexer.Lexer.init(source);
    var p = parser.Parser.init(&scanner, allocator);
    const ast_root = try p.parse();

    if (p.had_error) {
        return error.CompileError;
    }

    var chunk = chunk_mod.Chunk.init(allocator);
    var comp = compiler.Compiler.init(allocator, &chunk);
    try comp.compile(ast_root);
    try chunk.write(@intFromEnum(chunk_mod.OpCode.OP_RETURN), 0);

    const script_function = try allocator.create(value_mod.FunctionObj);
    script_function.* = .{
        .obj = .{ .obj_type = .Function, .next = null },
        .arity = 0,
        .chunk = chunk,
        .name = null,
        .can_fail = true,
    };

    try vm.interpret(script_function);
}

test {
    _ = @import("compiler/lexer.zig");
    _ = @import("compiler/parser.zig");
}
