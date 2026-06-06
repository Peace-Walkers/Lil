const std = @import("std");
const lil = @import("lil");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdin_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;
    var stdin_file_reader: std.Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    // init vm io
    const vm_io = lil.VmIo{
        .system = io,
        .in = stdin_reader,
        .out = stdout_writer,
    };

    const file_path = args[1];

    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, file_path, arena, .unlimited);
    defer arena.free(source);

    var vm = try lil.VM.init(arena, vm_io);
    defer vm.deinit();

    try lil.stdlib.openAll(&vm);

    vm.module_stack[0] = file_path;
    vm.module_depth = 1;

    vm.eval(source) catch |err| {
        std.debug.print("\n[DEV] VM halted with error: {any}\n", .{err});
    };
}
