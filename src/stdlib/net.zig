const std = @import("std");
const value_mod = @import("../compiler/value.zig");
const VM = @import("../runtime/vm.zig").VM;
const Value = value_mod.Value;

fn isResultErr(res: Value) bool {
    if (res != .Object)
        return false;
    if (res.Object.obj_type == .Variant) {
        const obj = res.Object.toVariant();
        if (std.mem.eql(u8, obj.variant_name.chars, "Err"))
            return true;
    }

    return false;
}

pub fn fetch(vm: *anyopaque, arg_count: u8, args: [*]Value) Value {
    const v: *VM = @ptrCast(@alignCast(vm));

    if (arg_count != 1 or args[0] != .Object or args[0].Object.obj_type != .String) {
        return v.createResultErr("net::fetch expect exactly 1 string argument (URL)") catch unreachable;
    }

    const url_str = args[0].Object.toString().chars;

    var client = std.http.Client{
        .io = v.io.system,
        .allocator = v.allocator,
    };
    defer client.deinit();

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(v.allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(v.allocator, &buf);

    const res = client.fetch(.{
        .location = .{ .url = url_str },
        .method = .GET,
        .response_writer = &writer.writer,
    }) catch {
        return v.createResultErr("HTTP request failed (network error).") catch unreachable;
    };

    writer.writer.flush() catch {};

    var raw_body_slice = writer.writer.toArrayList();
    const body_slice = raw_body_slice.toOwnedSlice(v.allocator) catch unreachable;
    const body_str = v.createString(body_slice) catch unreachable;

    var result_table = v.createTable() catch unreachable;

    result_table.fields.put("status", .{ .Number = @intFromEnum(res.status) }) catch unreachable;
    result_table.fields.put("body", .{ .Object = &body_str.obj }) catch unreachable;

    return v.createResultOk(.{ .Object = &result_table.obj }) catch unreachable;
}

///This function take a Request Description Table:
///{
///     url: String,
///     headers: Map<String, String>,
///     body: String,
///     method: String,
///     keep_alive: Bool,
///     ContentLength: Number,
///}
pub fn request(vm: *anyopaque, arg_count: u8, args: [*]Value) Value {
    const v: *VM = @ptrCast(@alignCast(vm));

    if (arg_count != 1 or args[0] != .Object or args[0].Object.obj_type != .Table) {
        return v.createResultErr("net::request expect exactly 1 argument (Request Description Table)") catch unreachable;
    }

    const request_description_table = args[0].Object.toTable();

    const rdt = fill_table(v, request_description_table) catch {
        return v.createResultErr("net::Request expected Request Description Table as parameter") catch unreachable;
    };

    var client = std.http.Client{
        .io = v.io.system,
        .allocator = v.allocator,
    };
    defer client.deinit();

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(v.allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(v.allocator, &buf);

    const method = rdt.to_methode() catch {
        return v.createResultErr("net::request Unknown method") catch unreachable;
    };

    const headers = rdt.to_headers(v.allocator) catch unreachable;

    var fetch_opt = std.http.Client.FetchOptions{
        .method = method,
        .location = .{ .url = rdt.url },
        .response_writer = &writer.writer,
    };

    if (rdt.body) |body| {
        fetch_opt.payload = body;
    }

    if (rdt.keep_alive) |ka| {
        fetch_opt.keep_alive = ka;
    }

    if (headers) |h| {
        fetch_opt.extra_headers = h;
    }

    const res = client.fetch(fetch_opt) catch {
        return v.createResultErr("HTTP request failed (network error).") catch unreachable;
    };

    writer.writer.flush() catch {};

    var raw_body_slice = writer.writer.toArrayList();
    const body_slice = raw_body_slice.toOwnedSlice(v.allocator) catch unreachable;
    const body_str = v.createString(body_slice) catch unreachable;

    var result_table = v.createTable() catch unreachable;

    result_table.fields.put("status", .{ .Number = @intFromEnum(res.status) }) catch unreachable;
    result_table.fields.put("body", .{ .Object = &body_str.obj }) catch unreachable;

    return v.createResultOk(.{ .Object = &result_table.obj }) catch unreachable;
}

pub fn listen(vm: *anyopaque, arg_count: u8, args: [*]Value) Value {
    const v: *VM = @ptrCast(@alignCast(vm));

    if (arg_count != 2 or args[0] != .Object or args[0].Object.obj_type != .String or args[1] != .Number) {
        std.log.info("found: {s} and {s}", .{ @tagName(args[0]), @tagName(args[1].Object.obj_type) });
        return v.createResultErr("net::listen() accept only two args 'host: String' and 'port: Number'.") catch unreachable;
    }

    const io = v.io.system;
    const host = args[0].Object.toString().chars;
    const port: u16 = @intCast(args[1].Number);
    const address = std.Io.net.IpAddress.parseIp4(host, port) catch unreachable;

    const server_ptr = v.allocator.create(std.Io.net.Server) catch unreachable;
    server_ptr.* = address.listen(io, .{ .reuse_address = true }) catch {
        return v.createResultErr("Failed to listen.") catch unreachable;
    };

    const sys_obj = v.createSystem(.TcpServer, server_ptr) catch unreachable;

    const accept_val = v.createNative("accept", accept) catch unreachable;
    const close_val = v.createNative("close", close) catch unreachable;

    sys_obj.methods.put("accept", accept_val) catch unreachable;
    sys_obj.methods.put("close", close_val) catch unreachable;

    const res = v.createResultOk(.{ .Object = &sys_obj.obj }) catch unreachable;
    return res;
}

pub fn accept(vm: *anyopaque, arg_count: u8, args: [*]Value) Value {
    const v: *VM = @ptrCast(@alignCast(vm));

    if (arg_count != 1) {
        return v.createResultErr("Server.accept() do not need args") catch unreachable;
    }

    if (args[0] != .Object or args[0].Object.obj_type != .System) {
        return v.createResultErr("accept() must be called on a System object") catch unreachable;
    }

    const sys_obj = args[0].Object.toSystem();
    if (sys_obj.kind != .TcpServer) {
        return v.createResultErr("accept() can only be called on a TcpServer") catch unreachable;
    }
    const io = v.io.system;

    const server_ptr: *std.Io.net.Server = @ptrCast(@alignCast(sys_obj.ptr));

    const connection = server_ptr.accept(io) catch {
        return v.createResultErr("Failed to accept client connection.") catch unreachable;
    };

    const conn_ptr = v.allocator.create(std.Io.net.Stream) catch unreachable;
    conn_ptr.* = connection;

    const client_obj = v.createSystem(.TcpClient, conn_ptr) catch unreachable;

    const recv_val = v.createNative("recv", recv) catch unreachable;
    const send_val = v.createNative("send", send) catch unreachable;
    const close_val = v.createNative("close", close) catch unreachable;

    client_obj.methods.put("recv", recv_val) catch unreachable;
    client_obj.methods.put("send", send_val) catch unreachable;
    client_obj.methods.put("close", close_val) catch unreachable;

    const res = v.createResultOk(.{ .Object = &client_obj.obj }) catch unreachable;
    return res;
}

pub fn recv(vm: *anyopaque, arg_count: u8, args: [*]Value) Value {
    const v: *VM = @ptrCast(@alignCast(vm));

    _ = arg_count;

    const sys_obj = args[0].Object.toSystem();
    if (sys_obj.kind != .TcpClient) {
        return v.createResultErr("recv() can only be called on a TcpClient") catch unreachable;
    }

    const io = v.io.system;
    const conn_ptr: *std.Io.net.Stream = @ptrCast(@alignCast(sys_obj.ptr));

    var buf: [4096]u8 = undefined;
    var reader = conn_ptr.reader(io, &buf);
    const data = reader.interface.peekGreedy(1) catch { // bloque ici
        return v.createResultErr("Failed to read from socket.") catch unreachable;
    };

    const raw_data = data;
    const string_obj = v.createString(raw_data) catch unreachable;

    reader.interface.toss(data.len);

    const res = v.createResultOk(.{ .Object = &string_obj.obj }) catch unreachable;
    return res;
}

pub fn send(vm: *anyopaque, arg_count: u8, args: [*]Value) Value {
    const v: *VM = @ptrCast(@alignCast(vm));

    if (arg_count != 2) {
        return v.createResultErr("client.send() expects exactly 1 argument (String)") catch unreachable;
    }

    if (args[0] != .Object or args[0].Object.obj_type != .System) {
        return v.createResultErr("send() must be called on a System object") catch unreachable;
    }
    if (args[1] != .Object or args[1].Object.obj_type != .String) {
        return v.createResultErr("client.send() payload must be a String") catch unreachable;
    }

    const sys_obj = args[0].Object.toSystem();
    if (sys_obj.kind != .TcpClient) {
        return v.createResultErr("send() can only be called on a TcpClient") catch unreachable;
    }

    const payload = args[1].Object.toString().chars;
    const io = v.io.system;
    const conn_ptr: *std.Io.net.Stream = @ptrCast(@alignCast(sys_obj.ptr));

    var buf: [4096]u8 = undefined;
    var writer = conn_ptr.writer(io, &buf);

    writer.interface.writeAll(payload) catch {
        return v.createResultErr("Failed to write to socket.") catch unreachable;
    };

    writer.interface.flush() catch unreachable;

    return v.createResultOk(.Null) catch unreachable;
}

pub fn close(vm: *anyopaque, arg_count: u8, args: [*]Value) Value {
    const v: *VM = @ptrCast(@alignCast(vm));

    if (arg_count != 1) {
        return v.createResultErr("close() takes no arguments") catch unreachable;
    }

    if (args[0] != .Object or args[0].Object.obj_type != .System) {
        return v.createResultErr("close() must be called on a System object") catch unreachable;
    }

    const sys_obj = args[0].Object.toSystem();
    const io = v.io.system;

    switch (sys_obj.kind) {
        .TcpClient => {
            const conn_ptr: *std.Io.net.Stream = @ptrCast(@alignCast(sys_obj.ptr));
            conn_ptr.close(io);
        },
        .TcpServer => {
            const server_ptr: *std.Io.net.Server = @ptrCast(@alignCast(sys_obj.ptr));
            server_ptr.deinit(io);
        },
        else => {
            return v.createResultErr("close() not implemented for this system object") catch unreachable;
        },
    }

    return v.createResultOk(.Null) catch unreachable;
}

///RDT is for Request Descriptor Table
const RDT = struct {
    url: []const u8,
    method: ?[]const u8,
    keep_alive: ?bool,
    headers: ?std.StringHashMap([]const u8),
    body: ?[]const u8,
    content_length: ?usize,

    pub fn to_methode(self: RDT) !std.http.Method {
        const method = self.method orelse return error.MethodNotProvided;
        if (std.mem.eql(u8, method, "GET")) return .GET;
        if (std.mem.eql(u8, method, "POST")) return .POST;
        if (std.mem.eql(u8, method, "OPTIONS")) return .OPTIONS;
        if (std.mem.eql(u8, method, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, method, "CONNECT")) return .CONNECT;
        if (std.mem.eql(u8, method, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, method, "PATCH")) return .PATCH;
        if (std.mem.eql(u8, method, "PUT")) return .PUT;
        if (std.mem.eql(u8, method, "TRACE")) return .TRACE;

        return error.UnkonwnMethod;
    }

    pub fn to_headers(self: RDT, allocator: std.mem.Allocator) !?[]std.http.Header {
        if (self.headers) |headers| {
            var it = headers.iterator();
            var http_headers: std.ArrayList(std.http.Header) = .empty;
            errdefer http_headers.deinit(allocator);
            while (it.next()) |entry| {
                const new_entry = std.http.Header{
                    .name = entry.key_ptr.*,
                    .value = entry.value_ptr.*,
                };

                try http_headers.append(allocator, new_entry);
            }

            return try http_headers.toOwnedSlice(allocator);
        }
        return null;
    }
};

///The purpose of this function is to taque a resques description
/// - check mandatory fields presence
/// - fill missing optional fields with default values
fn fill_table(v: *VM, t: *value_mod.TableObj) !RDT {
    const v_url = try v.expectField(t, "url", .String);
    if (isResultErr(v_url)) return error.MissingField;
    const url = v_url.asString() orelse return error.InvalidField;

    return .{
        .url = url,
        .method = get_table_field_to_string(t, "method") orelse "GET",
        .headers = try get_table_field_to_map(v.allocator, t, "headers"),
        .body = get_table_field_to_string(t, "body"),
        .keep_alive = get_table_field_to_bool(t, "keep_alive"),
        .content_length = get_table_field_to_number(t, "content_length"),
    };
}

fn get_table_field_to_string(t: *value_mod.TableObj, key: []const u8) ?[]const u8 {
    const f = t.fields.get(key) orelse return null;
    if (f.Object.obj_type != .String) return null;

    return f.Object.toString().chars;
}

fn get_table_field_to_map(allocator: std.mem.Allocator, t: *value_mod.TableObj, key: []const u8) !?std.StringHashMap([]const u8) {
    const f = t.fields.get(key) orelse return null;
    if (f.Object.obj_type != .Map) return null;
    const map = f.Object.toMap().hashmap;

    var it = map.iterator();
    var new_map = std.StringHashMap([]const u8).init(allocator);
    while (it.next()) |entry| {
        if (entry.key_ptr.* != .Object and entry.key_ptr.Object.obj_type != .String) return null;
        if (entry.value_ptr.* != .Object and entry.value_ptr.Object.obj_type != .String) return null;

        const new_key = entry.key_ptr.Object.toString().chars;
        const new_value = entry.key_ptr.Object.toString().chars;

        try new_map.put(new_key, new_value);
    }

    return new_map;
}

fn get_table_field_to_bool(t: *value_mod.TableObj, key: []const u8) ?bool {
    const f = t.fields.get(key) orelse return null;
    if (f != .Boolean) return null;

    return f.Boolean;
}

fn get_table_field_to_number(t: *value_mod.TableObj, key: []const u8) ?usize {
    const f = t.fields.get(key) orelse return null;
    if (f != .Number) return null;

    return @intCast(f.Number);
}
