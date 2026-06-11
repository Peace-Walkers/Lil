pub const io = @import("io.zig");
pub const fs = @import("fs.zig");
pub const net = @import("net.zig");

pub const methods = @import("methods/methods.zig");

const VM = @import("../runtime/vm.zig").VM;

pub fn openIo(vm: *VM) !void {
    var io_module = try vm.createTable();
    try vm.bindNative(io_module, "read", io.read);
    try vm.bindNative(io_module, "print", io.print);
    try vm.bindNative(io_module, "println", io.println);

    try vm.setGlobal("io", .{ .Object = &io_module.obj });
}

pub fn openFs(vm: *VM) !void {
    var fs_module = try vm.createTable();
    try vm.bindNative(fs_module, "stat", fs.stat);

    try vm.setGlobal("fs", .{ .Object = &fs_module.obj });
}

pub fn openNet(vm: *VM) !void {
    var net_module = try vm.createTable();
    try vm.bindNative(net_module, "fetch", net.fetch);
    try vm.bindNative(net_module, "request", net.request);
    try vm.bindNative(net_module, "recv", net.recv);

    try vm.setGlobal("net", .{ .Object = &net_module.obj });
}

pub fn openAll(vm: *VM) !void {
    try openIo(vm);
    try openFs(vm);
    try openNet(vm);
}
