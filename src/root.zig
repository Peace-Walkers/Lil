const std = @import("std");
const lexer = @import("compiler/lexer.zig");
const parser = @import("compiler/parser.zig");
const chunk_mod = @import("compiler/chunk.zig");
const compiler = @import("compiler/compiler.zig");
const debug = @import("compiler/debug.zig");
const VM = @import("runtime/vm.zig").VM;

pub fn interpret(allocator: std.mem.Allocator, source: []const u8) !void {
    var scanner = lexer.Lexer.init(source);

    var p = parser.Parser.init(&scanner, allocator);
    const ast_root = try p.parse();

    if (p.had_error) {
        return error.CompileError;
    }

    var chunk = chunk_mod.Chunk.init(allocator);
    defer chunk.deinit();

    var comp = compiler.Compiler.init(allocator, &chunk);
    try comp.compile(ast_root);

    try chunk.write(@intFromEnum(chunk_mod.OpCode.OP_RETURN), 0);

    try debug.disassembleChunk(&chunk, "Bytecode");

    std.debug.print("Compilation réussie ! Le Chunk contient {d} octets et {d} constantes.\n", .{
        chunk.code.items.len,
        chunk.constants.items.len,
    });

    var vm = VM.init(allocator);
    defer vm.deinit();
    try vm.interpret(&chunk);
}

test {
    _ = @import("compiler/lexer.zig");
}
