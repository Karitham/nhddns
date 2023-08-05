const std = @import("std");
const Self = @This();

username: []const u8,
password: []const u8,
hostname: []const u8,
registry: []const u8 = "domains.google.com",
email: ?[]const u8 = null,
tls: bool = true,

pub fn update(ddns: Self, alloc: std.mem.Allocator, addr: std.net.Address) !enum { NoChange, Good } {
    var headers: std.http.Headers = .{ .allocator = alloc };

    var ua = try ddns.userAgent(alloc);
    defer alloc.free(ua);
    try headers.append("User-Agent", ua);

    var ba = try ddns.basicAuth(alloc);
    defer alloc.free(ba);
    try headers.append("Authorization", ba);

    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    var req = try client.request(.GET, try ddns.requestUri(alloc, addr), headers, .{});
    defer req.deinit();

    try req.start();
    try req.wait();

    const out = try req.reader().readAllAlloc(alloc, 12 * 1024);
    defer alloc.free(out);

    if (std.mem.indexOf(u8, out, "good") != null) return .Good;
    if (std.mem.indexOf(u8, out, "nochg") != null) return .NoChange;

    std.log.warn("{s}", .{out});
    return error.CouldNotSetIP;
}

/// caller owns memory
pub fn requestUri(self: Self, arena: std.mem.Allocator, addr: std.net.Address) !std.Uri {
    var ipbuf = std.ArrayList(u8).init(arena);
    try ipbuf.writer().print("{}", .{addr});
    defer ipbuf.deinit();

    var revIter = std.mem.reverseIterator(ipbuf.items);

    while (revIter.next()) |c| {
        _ = ipbuf.pop();
        if (c == ':') break;
    }

    var query = std.ArrayList(u8).init(arena);
    try query.writer().print("hostname={s}", .{self.hostname});
    try query.writer().print("&myip={s}", .{ipbuf.items});

    return std.Uri{
        .port = if (self.tls) 443 else 80,
        .host = self.registry,
        .path = "/nic/update",
        .query = try query.toOwnedSlice(),
        .scheme = if (self.tls) "https" else "http",
        .user = self.username,
        .password = self.password,
        .fragment = null,
    };
}

test requestUri {
    var ddns = Self{
        .username = "user",
        .password = "pass",
        .hostname = "example.com",
        .email = "email",
        .registry = "domains.google.com",
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var uri = try ddns.requestUri(arena.allocator(), std.net.Address{
        .in = std.net.Ip4Address{
            .sa = std.os.sockaddr.in{
                .port = 0,
                .addr = 0x01010101,
            },
        },
    });
    var actual = try std.fmt.allocPrint(std.heap.page_allocator, "{+/}", .{uri});
    defer std.heap.page_allocator.free(actual);

    try std.testing.expectEqualStrings("https://user:pass@domains.google.com:443/nic/update?hostname=example.com&myip=1.1.1.1", actual);
}

/// caller owns returned memory
pub fn userAgent(self: Self, alloc: std.mem.Allocator) ![]const u8 {
    if (self.email == null) return alloc.dupe(u8, "nhddns/0.1");
    return std.fmt.allocPrint(alloc, "nhddns/0.1 {s}", .{self.email.?});
}

test userAgent {
    {
        const ddns = Self{
            .username = "user",
            .password = "pass",
            .hostname = "host",
            .email = "email",
        };

        const ua = try ddns.userAgent(std.testing.allocator);
        defer std.testing.allocator.free(ua);

        try std.testing.expectEqualSlices(u8, "nhddns/0.1 email", ua);
    }
    {
        const ddns = Self{
            .username = "user",
            .password = "pass",
            .hostname = "host",
            .email = null,
        };

        const ua = try ddns.userAgent(std.testing.allocator);
        defer std.testing.allocator.free(ua);

        try std.testing.expectEqualSlices(u8, "nhddns/0.1", ua);
    }
}

// caller owns returned memory
pub fn basicAuth(self: Self, alloc: std.mem.Allocator) ![]const u8 {
    const us = try std.fmt.allocPrint(alloc, "{s}:{s}", .{
        self.username,
        self.password,
    });
    defer alloc.free(us);

    var outbuf = try alloc.alloc(u8, std.base64.url_safe.Encoder.calcSize(us.len));
    defer alloc.free(outbuf);

    const o = std.base64.url_safe.Encoder.encode(outbuf, us);

    return std.fmt.allocPrint(alloc, "Basic {s}", .{o});
}

test basicAuth {
    var ddns = Self{
        .username = "user",
        .password = "pass",
        .hostname = "example.com",
    };

    const actual = try ddns.basicAuth(std.testing.allocator);
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualSlices(u8, "Basic dXNlcjpwYXNz", actual);
}
