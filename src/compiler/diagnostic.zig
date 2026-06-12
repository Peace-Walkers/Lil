const std = @import("std");
const ParseError = @import("parser.zig").ParseError;

pub const ErrorReporter = struct {
    ptr: *anyopaque,
    reportRawFn: *const fn (ptr: *anyopaque, line: usize, message: []const u8) anyerror!void,

    pub fn report(
        self: ErrorReporter,
        allocator: std.mem.Allocator,
        line: usize,
        comptime format: []const u8,
        args: anytype,
    ) ParseError!void {
        const msg = try std.fmt.allocPrint(allocator, format, args);
        self.reportRawFn(self.ptr, line, msg) catch {
            return ParseError.ReportError;
        };
    }
};

pub const Diagnostic = struct {
    line: usize,
    message: []const u8,
};

pub const ErrorAccumulator = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    errors: std.ArrayList(Diagnostic),
    has_error: bool = false,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .errors = .empty,
        };
    }

    fn reportRaw(ptr: *anyopaque, line: usize, message: []const u8) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        try self.errors.append(self.allocator, .{ .line = line, .message = message });
        self.has_error = true;
    }

    pub fn reporter(self: *Self) ErrorReporter {
        return .{
            .ptr = self,
            .reportRawFn = reportRaw,
        };
    }

    pub fn printErrors(self: *Self) void {
        if (!self.has_error) return;

        std.debug.print("\nCompilation failed with {} error(s):\n", .{self.errors.items.len});
        for (self.errors.items) |diag| {
            std.debug.print("  [Line {d}] {s}\n", .{ diag.line, diag.message });
        }
    }
};
