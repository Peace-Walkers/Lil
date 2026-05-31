const std = @import("std");
const lexer = @import("compiler/lexer.zig");
const parser = @import("compiler/parser.zig");
const chunk_mod = @import("compiler/chunk.zig");
const value_mod = @import("compiler/value.zig");
const compiler = @import("compiler/compiler.zig");
const debug = @import("compiler/debug.zig");
const VM = @import("runtime/vm.zig").VM;

const stdlib_sources = [_][]const u8{
    @embedFile("stdlib_lil/io.lil"),
    // @embedFile("stdlib_lil/table.lil"), // Tu pourras décommenter quand tu le créeras
    // @embedFile("stdlib_lil/string.lil"),
};

pub fn interpret(allocator: std.mem.Allocator, source: []const u8) !void {
    var vm = try VM.init(allocator);
    defer vm.deinit();

    for (stdlib_sources) |std_source| {
        var core_scanner = lexer.Lexer.init(std_source);
        var core_parser = parser.Parser.init(&core_scanner, allocator);
        const core_ast = try core_parser.parse();

        if (core_parser.had_error) {
            std.debug.print("Compile error in stdlib internal !\n", .{});
            return error.CompileError;
        }

        var core_chunk = chunk_mod.Chunk.init(allocator);
        var core_comp = compiler.Compiler.init(allocator, &core_chunk);
        try core_comp.compile(core_ast);
        try core_chunk.write(@intFromEnum(chunk_mod.OpCode.OP_RETURN), 0);

        const core_function = try allocator.create(value_mod.FunctionObj);
        core_function.* = .{
            .obj = .{ .obj_type = .Function, .next = null },
            .arity = 0,
            .chunk = core_chunk,
            .name = null,
        };

        try vm.interpret(core_function);
    }

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
    };

    try vm.interpret(script_function);
}

test {
    _ = @import("compiler/lexer.zig");
    _ = @import("compiler/parser.zig");
}
