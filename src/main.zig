const std = @import("std");
const Io = std.Io;

const lil = @import("lil");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdin_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;
    var stdin_file_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    const vm_io = lil.VmIo{
        .system = io,
        .in = stdin_reader,
        .out = stdout_writer,
    };

    if (args.len == 1) {
        try stdout_writer.print("LiLang v0.1.0 - REPL (Ctrl + C to exit)\n", .{});
        try stdout_writer.flush();
        while (true) {
            try stdout_writer.print("> ", .{});
            try stdout_writer.flush();

            const line_or_eof = stdin_reader.readSliceShort(&stdin_buffer) catch |err| {
                if (err == error.EndOfStream) {
                    break;
                }
                break;
            };
            std.log.info("read finish", .{});
            if (line_or_eof != 0) {} else {
                try stdout_writer.print("\nBye!\n", .{});
                break;
            }
            std.debug.print("line: {s}\n", .{&stdin_buffer});
            try lil.interpret(vm_io, arena, stdin_buffer[0..line_or_eof]);
        }
    } else if (args.len == 2) {
        const file_path = args[1];
        const source = std.Io.Dir.cwd().readFileAlloc(io, file_path, arena, .unlimited) catch |err| {
            try stdout_writer.print("Error: Failed to read '{s}' ({})\n", .{ file_path, err });
            return;
        };

        try lil.interpret(vm_io, arena, source);
    } else {
        try stdout_writer.print("Usage: lilang <script path>\n", .{});
    }
}

test "run all compiler tests" {
    _ = @import("lil");
}
