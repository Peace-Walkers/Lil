const std = @import("std");
const value_mod = @import("compiler/value.zig");

pub const VM = @import("runtime/vm.zig").VM;
pub const VmIo = @import("runtime/vm.zig").VmIo;
pub const Value = value_mod.Value;
pub const stdlib = @import("stdlib/stdlib.zig");
pub const ResolvedModule = @import("runtime/vm.zig").ResolvedModule;

test {
    _ = @import("compiler/lexer.zig");
    _ = @import("compiler/parser.zig");
}
