const std = @import("std");

/// unmarshalEnvMap loads from envmap.
/// It takes a struct type and a prefix. It will load all fields of the struct
/// such that the field name is the environment variable name with the prefix.
///
/// the memory used in T is that of the envmap. If you want to keep the data
/// around, avoid freeing it.
pub fn unmarshalEnvMap(T: anytype, comptime prefix: []const u8, env: std.process.EnvMap) !T {
    var out: T = std.mem.zeroInit(T, .{});

    inline for (std.meta.fields(T)) |field| {
        const name = x: {
            var name = prefix ++ field.name;
            var outName: [name.len]u8 = undefined;

            for (0..name.len) |i| outName[i] = std.ascii.toUpper(name[i]);

            break :x &outName;
        };

        if (env.get(name)) |value| {
            const v = try unmarshalValue(field.type, value);
            @field(out, field.name) = v;
        }
    }

    return out;
}

fn unmarshalValue(T: anytype, value: []const u8) !T {
    return switch (@typeInfo(T)) {
        .Optional => |o| if (value.len == 0) null else try unmarshalValue(o.child, value),
        .Bool => std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1"),
        .ComptimeInt, .Int => try std.fmt.parseInt(T, value, 10),
        .Float => try std.fmt.parseFloat(T, value),
        else => if (std.meta.trait.isZigString(T)) value else error.InvalidType,
    };
}

test unmarshalEnvMap {
    const Options = struct {
        username: []const u8,
        password: []const u8,
        hostname: []const u8,
        registry: []const u8,
        email: ?[]const u8,
        tls: bool,
    };

    const testing = std.testing;

    var em = std.process.EnvMap.init(testing.allocator);
    defer em.deinit();
    try em.put("NHDDNS_USERNAME", "user");
    try em.put("NHDDNS_PASSWORD", "pass");
    try em.put("NHDDNS_HOSTNAME", "host");
    try em.put("NHDDNS_REGISTRY", "domains.google.com");
    try em.put("NHDDNS_EMAIL", "email");
    try em.put("NHDDNS_TLS", "true");

    var options = try unmarshalEnvMap(Options, "NHDDNS_", em);

    try std.testing.expectEqualSlices(u8, options.username, "user");
    try std.testing.expectEqualSlices(u8, options.password, "pass");
    try std.testing.expectEqualSlices(u8, options.hostname, "host");
    try std.testing.expectEqualSlices(u8, options.registry, "domains.google.com");
    try std.testing.expectEqualSlices(u8, options.email.?, "email");
    try std.testing.expectEqual(options.tls, true);

    // defaults
    var em2 = std.process.EnvMap.init(testing.allocator);
    defer em2.deinit();
    options = try unmarshalEnvMap(Options, "NHDDNS_", em2);

    try std.testing.expectEqualSlices(u8, options.username, "");
    try std.testing.expectEqualSlices(u8, options.password, "");
    try std.testing.expectEqualSlices(u8, options.hostname, "");
    try std.testing.expectEqualSlices(u8, options.registry, "");
    try std.testing.expectEqual(options.email, null);
    try std.testing.expectEqual(options.tls, false);
}

test unmarshalValue {
    var x = try unmarshalValue(bool, "true");
    try std.testing.expectEqual(x, true);

    x = try unmarshalValue(bool, "1");
    try std.testing.expectEqual(x, true);

    x = try unmarshalValue(bool, "false");
    try std.testing.expectEqual(x, false);

    x = try unmarshalValue(bool, "0");
    try std.testing.expectEqual(x, false);

    var string = try unmarshalValue([]const u8, "string");
    try std.testing.expectEqualSlices(u8, string, "string");

    var maybe = try unmarshalValue(?[]const u8, "not a bool");
    try std.testing.expectEqualSlices(u8, maybe.?, "not a bool");

    var i = try unmarshalValue(i32, "123");
    try std.testing.expectEqual(i, 123);

    var f = try unmarshalValue(f32, "123.456");
    try std.testing.expectEqual(f, 123.456);

    maybe = try unmarshalValue(?[]const u8, "123.456");
    try std.testing.expectEqualSlices(u8, maybe.?, "123.456");

    var neg = try unmarshalValue(i32, "-1");
    try std.testing.expectEqual(neg, -1);
}
