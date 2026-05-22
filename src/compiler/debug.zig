const std = @import("std");
const chunk_mod = @import("chunk.zig");
const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;

pub fn disassembleChunk(chunk: *Chunk, name: []const u8) !void {
    std.debug.print("\n=== {s} ===\n", .{name});
    std.debug.print("ADDR LINE OPCODE           OPERAND   DETAILS\n", .{});
    std.debug.print("--------------------------------------------\n", .{});

    var offset: usize = 0;
    while (offset < chunk.code.items.len) {
        offset = try disassembleInstruction(chunk, offset);
    }
    std.debug.print("--------------------------------------------\n", .{});
}

pub fn disassembleInstruction(chunk: *Chunk, offset: usize) !usize {
    std.debug.print("{d:0>4} ", .{offset});

    if (offset > 0 and chunk.lines.items[offset] == chunk.lines.items[offset - 1]) {
        std.debug.print("   | ", .{});
    } else {
        std.debug.print("{d:>4} ", .{chunk.lines.items[offset]});
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
        .OP_POP => return simpleInstruction("OP_POP", offset),
        .OP_GET_LOCAL => return byteInstruction("OP_GET_LOCAL", chunk, offset),
        .OP_SET_LOCAL => return byteInstruction("OP_SET_LOCAL", chunk, offset),
        .OP_JUMP => return jumpInstruction("OP_JUMP", 1, chunk, offset),
        .OP_JUMP_IF_FALSE => return jumpInstruction("OP_JUMP_IF_FALSE", 1, chunk, offset),
        else => {
            std.debug.print("{s:<16}\n", .{@tagName(op)});
            return offset + 1;
        },
    }
}

fn simpleInstruction(name: []const u8, offset: usize) usize {
    std.debug.print("{s:<16}\n", .{name});
    return offset + 1;
}

fn constantInstruction(name: []const u8, chunk: *Chunk, offset: usize) usize {
    const constant_index = chunk.code.items[offset + 1];

    std.debug.print("{s:<16} {d:<9} [val: ", .{ name, constant_index });
    chunk.constants.items[constant_index].print();
    std.debug.print("]\n", .{});

    return offset + 2;
}

fn byteInstruction(name: []const u8, chunk: *Chunk, offset: usize) usize {
    const slot = chunk.code.items[offset + 1];

    std.debug.print("{s:<16} {d:<9} [slot]\n", .{ name, slot });

    return offset + 2;
}

fn jumpInstruction(name: []const u8, sign: i32, chunk: *Chunk, offset: usize) usize {
    const jump: u16 = (@as(u16, chunk.code.items[offset + 1]) << 8) | chunk.code.items[offset + 2];

    const target: usize = if (sign == 1) offset + 3 + jump else offset + 3 - jump;

    std.debug.print("{s:<16} {d:<9} [target: {d:0>4}]\n", .{ name, jump, target });

    return offset + 3;
}
