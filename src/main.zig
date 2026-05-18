const std = @import("std");
const Io = std.Io;

const lil = @import("lil");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    var vm = lil.VM.init(arena);
    defer vm.deinit();

    if (args.len == 1) {
        try stdout_writer.print("LiLang v0.1.0 - REPL (Ctrl + C to exit)\n", .{});
        try stdout_writer.flush();
    } else if (args.len == 2) {
        const file_path = args[1];
        const source = std.Io.Dir.cwd().readFileAlloc(io, file_path, arena, .unlimited) catch |err| {
            try stdout_writer.print("Error: Failed to read '{s}' ({})\n", .{ file_path, err });
            return;
        };

        try vm.interpret(source);
    } else {
        try stdout_writer.print("Usage: lilang <script path>\n", .{});
    }
}
