const std = @import("std");
const chunk_mod = @import("chunk.zig");
const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;

pub fn disassembleChunk(chunk: *Chunk, name: []const u8) !void {
    std.debug.print("== {s} ==\n", .{name});

    var offset: usize = 0;
    while (offset < chunk.code.items.len) {
        offset = try disassembleInstruction(chunk, offset);
    }
}

pub fn disassembleInstruction(chunk: *Chunk, offset: usize) !usize {
    std.debug.print("{d:0>4}", .{offset});

    if (offset > 0 and chunk.lines.items[offset] == chunk.lines.items[offset - 1]) {
        std.debug.print("   | ", .{});
    } else {
        std.debug.print("{d:4} ", .{chunk.lines.items[offset]});
    }

    const instruction = chunk.code.items[offset];

    const op: OpCode = @enumFromInt(instruction);
    switch (op) {
        .OP_CONSTANT => return constantInstruction("OP_CONSTANT", chunk, offset),
        .OP_DEFINE_GLOBAL => return constantInstruction("OP_DEFINE_GLOBAL", chunk, offset),
        .OP_GET_GLOBAL => return constantInstruction("OP_GET_GLOBAL", chunk, offset),
        .OP_ADD => return simpleInstruction("OP_ADD", offset),
        .OP_SUBTRACT => return simpleInstruction("OP_SUBTRACT", offset),
        .OP_MULTIPLY => return simpleInstruction("OP_MULTIPLY", offset),
        .OP_DIVIDE => return simpleInstruction("OP_DIVIDE", offset),
        .OP_RETURN => return simpleInstruction("OP_RETURN", offset),
        else => {
            std.debug.print("Opcode non géré dans le debug: {s}\n", .{@tagName(op)});
            return offset + 1;
        },
    }
}

fn simpleInstruction(name: []const u8, offset: usize) usize {
    std.debug.print("{s}\n", .{name});
    return offset + 1; // Une instruction simple prend 1 octet
}

fn constantInstruction(name: []const u8, chunk: *Chunk, offset: usize) usize {
    const constant_index = chunk.code.items[offset + 1];

    std.debug.print("{s:<16} {d:4} '", .{ name, constant_index });

    chunk.constants.items[constant_index].print();

    std.debug.print("'\n", .{});

    return offset + 2;
}
