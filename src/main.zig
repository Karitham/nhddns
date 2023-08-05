const std = @import("std");
const utils = @import("./utils.zig");
const DDNS = @import("./dyndns2.zig");
const http = std.http;
const net = std.net;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var alloc = gpa.allocator();

    const new_ip = try resolveSelfAddress(alloc, "http://checkip.amazonaws.com");

    var env = try std.process.getEnvMap(alloc);
    defer env.deinit();

    var dir: ?std.fs.Dir = x: {
        const cache_dir: []const u8 = env.get("NHDDNS_CACHE_DIR") orelse "/var/cache/nhddns";
        std.fs.Dir.makePath(std.fs.cwd(), cache_dir) catch {
            std.log.debug("could not create cache dir: {s}, not using cache", .{cache_dir});
            break :x null;
        };

        break :x std.fs.Dir.openDir(std.fs.cwd(), cache_dir, .{}) catch null;
    };
    if (dir != null) {
        defer dir.?.close();

        const old_ip: ?net.Address = cachedAddress(dir.?) catch null;
        if (old_ip != null and old_ip.?.eql(new_ip)) return;

        cacheAddress(dir.?, new_ip) catch |err| {
            std.log.warn("could not cache address: {any}", .{err});
        };
    }

    const ddns: DDNS = try utils.unmarshalEnvMap(DDNS, "NHDDNS_", env);

    const result = try ddns.update(alloc, new_ip);
    switch (result) {
        .NoChange => {},
        .Good => std.log.info("updated addr to: {}", .{new_ip}),
    }
}

fn resolveSelfAddress(alloc: std.mem.Allocator, ipProvider: []const u8) !net.Address {
    const uri = try std.Uri.parse(ipProvider);

    var client = http.Client{
        .allocator = alloc,
    };
    defer client.deinit();

    var req = try client.request(.GET, uri, .{ .allocator = alloc }, .{});
    defer req.deinit();
    try req.start();
    try req.wait();

    var out = std.ArrayList(u8).init(alloc);
    req.reader().streamUntilDelimiter(out.writer(), '\n', 40) catch |err| {
        if (err != error.EndOfStream) return err;
    };

    defer out.deinit();

    return try std.net.Address.resolveIp(out.items, 0);
}

fn cacheAddress(cache_dir: std.fs.Dir, ip: net.Address) !void {
    var f = try cache_dir.createFile("nhddns.cache", std.fs.File.CreateFlags{});
    defer f.close();

    try f.writer().print("{}", .{ip});
}

fn cachedAddress(cache_dir: std.fs.Dir) !net.Address {
    var f = try cache_dir.openFile("nhddns.cache", .{});
    defer f.close();

    var buf: [40]u8 = undefined;
    var fbs = std.heap.FixedBufferAllocator.init(&buf);

    var out = std.ArrayList(u8).init(fbs.allocator());
    defer out.deinit();

    f.reader().streamUntilDelimiter(out.writer(), '\n', 40) catch |err| {
        if (err != error.EndOfStream) return err;
    };

    return try std.net.Address.resolveIp(out.items, 0);
}

test "getCurrentIP" {
    if (!testFull(std.testing.allocator)) return;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    _ = try resolveSelfAddress(arena.allocator(), "http://checkip.amazonaws.com");
    _ = try resolveSelfAddress(arena.allocator(), "https://domains.google.com/checkip");
}

fn testFull(alloc: std.mem.Allocator) bool {
    var env = std.process.getEnvMap(alloc) catch |err| {
        std.log.warn("could not get env: {any}", .{err});
        return false;
    };

    defer env.deinit();

    if (env.get("NHDDNS_TEST_FULL") != null) return true;

    return false;
}

test utils {
    std.testing.refAllDecls(utils);
    std.testing.refAllDecls(DDNS);
}
