const std = @import("std");
const http = std.http;
const net = std.net;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var alloc = arena.allocator();
    defer arena.deinit();

    var options = try loadFromEnv(DynDNS2Options, alloc, "NHDDNS_");

    try setIP(alloc, null, options);
}

/// loadFromEnv loads from environment.
/// It takes a struct type and a prefix. It will load all fields of the struct
/// such that the field name is the environment variable name with the prefix uppercased.
///
/// For example, if the prefix is "foo" and the struct has a field named
/// "barBaz", then the environment variable "FOO_BAR_BAZ" will be loaded into
/// that field.
fn loadFromEnv(T: anytype, alloc: std.mem.Allocator, prefix: []const u8) !T {
    var out: T = std.mem.zeroInit(T, .{});
    const env = try std.process.getEnvMap(alloc);

    const prefixUp = try std.ascii.allocUpperString(alloc, prefix);
    defer alloc.free(prefixUp);

    inline for (std.meta.fields(T)) |field| {
        const name = field.name;
        var envName = std.ArrayList(u8).init(alloc);
        defer envName.deinit();

        try envName.appendSlice(prefixUp);
        const o = try std.ascii.allocUpperString(alloc, name);
        defer alloc.free(o);
        try envName.appendSlice(o);

        if (env.get(envName.items)) |value| {
            if (comptime field.type == []const u8) {
                @field(out, field.name) = value;
            }
        }
    }

    return out;
}

const DynDNS2Options = struct {
    username: []const u8,
    password: []const u8,
    hostname: []const u8,
    registry: []const u8 = "domains.google.com",
    email: []const u8,
    tls: bool = true,

    // caller owns returned memory
    fn buildURI(self: DynDNS2Options, arena: std.mem.Allocator, ip: ?net.Address) error{BadOptions}!std.Uri {
        const ipstr: ?[]const u8 = x: {
            if (ip == null) break :x null;

            var ipbuf = std.ArrayList(u8).init(arena);
            ipbuf.writer().print("{}", .{ip.?}) catch return error.BadOptions;

            for (ipbuf.items, 0..) |c, i| {
                if (c == ':') // don't include port
                    break :x ipbuf.items[0..i];
            }

            break :x ipbuf.items;
        };

        var query = std.ArrayList(u8).init(arena);
        defer query.deinit();
        query.writer().print("hostname={s}", .{self.hostname}) catch return error.BadOptions;

        if (ipstr) |i| {
            query.writer().print("&myip={s}", .{i}) catch return error.BadOptions;
        }

        return std.Uri{
            .port = if (self.tls) 443 else 80,
            .host = self.registry,
            .path = "/nic/update",
            .query = query.toOwnedSlice() catch return error.BadOptions,
            .scheme = if (self.tls) "https" else "http",
            .user = self.username,
            .password = self.password,
            .fragment = null,
        };
    }

    fn userAgent(self: DynDNS2Options, alloc: std.mem.Allocator) ![]const u8 {
        var out = std.ArrayList(u8).init(alloc);
        defer out.deinit();

        try out.writer().print("nhddns/0.1 {s}", .{self.email});
        return out.toOwnedSlice();
    }

    fn basicAuth(self: DynDNS2Options, alloc: std.mem.Allocator) ![]const u8 {
        const us = x: {
            var out = std.ArrayList(u8).init(alloc);
            defer out.deinit();

            try out.writer().print("{s}:{s}", .{ self.username, self.password });
            break :x try out.toOwnedSlice();
        };

        var out = std.ArrayList(u8).init(alloc);
        defer out.deinit();
        try out.appendSlice("Basic ");

        var outbuf = try alloc.alloc(u8, std.base64.url_safe.Encoder.calcSize(us.len));
        try out.appendSlice(
            std.base64.url_safe.Encoder.encode(outbuf, us),
        );
        return out.toOwnedSlice();
    }
};

fn setIP(alloc: std.mem.Allocator, ip: ?net.Address, opt: DynDNS2Options) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var client = http.Client{
        .allocator = alloc,
    };

    var headers: http.Headers = .{ .allocator = alloc };
    try headers.append("User-Agent", try opt.userAgent(arena.allocator()));

    const a = try opt.basicAuth(arena.allocator());
    try headers.append("Authorization", a);

    const uri = try opt.buildURI(arena.allocator(), ip);

    var req = try client.request(.GET, uri, headers, http.Client.Options{
        .max_redirects = 6,
    });
    defer req.deinit();

    try req.start();
    try req.wait();

    var out = std.ArrayList(u8).init(alloc);
    try req.reader().readAllArrayList(&out, 12 * 1024);
    defer out.deinit();

    if (std.mem.indexOf(u8, out.items, "good") == null and
        std.mem.indexOf(u8, out.items, "nochg") == null)
    {
        std.log.warn("{s}", .{out.items});
        return error.BadOptions;
    }

    std.log.info("success", .{});
}

fn getCurrentIP(alloc: std.mem.Allocator) !net.Address {
    var client = http.Client{
        .allocator = alloc,
    };

    const uri = try std.Uri.parse("http://checkip.amazonaws.com");

    var req = try client.request(.GET, uri, .{ .allocator = alloc }, .{});
    defer req.deinit();
    try req.start();
    try req.wait();

    var out = std.ArrayList(u8).init(alloc);
    try req.reader().streamUntilDelimiter(out.writer(), '\n', null);
    defer out.deinit();

    return try std.net.Address.resolveIp(out.items, 0);
}
