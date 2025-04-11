//! Code shared across several IO implementations, because, eg, it is expressible via POSIX layer.
const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;

const assert = std.debug.assert;

const is_linux = builtin.target.os.tag == .linux;

pub const ListenOptions = struct {
    rcvbuf: c_int,
    sndbuf: c_int,
    keepalive: ?struct {
        keepidle: c_int,
        keepintvl: c_int,
        keepcnt: c_int,
    },
    user_timeout_ms: c_int,
    nodelay: bool,
    backlog: u31,
};

pub fn listen(
    fd: posix.socket_t,
    address: std.net.Address,
    options: ListenOptions,
) !std.net.Address {
    const set = struct {
        fn set(_fd: posix.socket_t, level: i32, option: u32, value: c_int) !void {
            try posix.setsockopt(_fd, level, option, &std.mem.toBytes(value));
        }
    }.set;

    if (options.rcvbuf > 0) rcvbuf: {
        if (is_linux) {
            // Requires CAP_NET_ADMIN privilege (settle for SO_RCVBUF in case of an EPERM):
            if (set(fd, posix.SOL.SOCKET, posix.SO.RCVBUFFORCE, options.rcvbuf)) |_| {
                break :rcvbuf;
            } else |err| switch (err) {
                error.PermissionDenied => {},
                else => |e| return e,
            }
        }
        try set(fd, posix.SOL.SOCKET, posix.SO.RCVBUF, options.rcvbuf);
    }

    if (options.sndbuf > 0) sndbuf: {
        if (is_linux) {
            // Requires CAP_NET_ADMIN privilege (settle for SO_SNDBUF in case of an EPERM):
            if (set(fd, posix.SOL.SOCKET, posix.SO.SNDBUFFORCE, options.sndbuf)) |_| {
                break :sndbuf;
            } else |err| switch (err) {
                error.PermissionDenied => {},
                else => |e| return e,
            }
        }
        try set(fd, posix.SOL.SOCKET, posix.SO.SNDBUF, options.sndbuf);
    }

    if (options.keepalive) |keepalive| {
        try set(fd, posix.SOL.SOCKET, posix.SO.KEEPALIVE, 1);
        if (is_linux) {
            try set(fd, posix.IPPROTO.TCP, posix.TCP.KEEPIDLE, keepalive.keepidle);
            try set(fd, posix.IPPROTO.TCP, posix.TCP.KEEPINTVL, keepalive.keepintvl);
            try set(fd, posix.IPPROTO.TCP, posix.TCP.KEEPCNT, keepalive.keepcnt);
        }
    }

    if (options.user_timeout_ms > 0) {
        if (is_linux) {
            const timeout_ms = options.user_timeout_ms;
            try set(fd, posix.IPPROTO.TCP, posix.TCP.USER_TIMEOUT, timeout_ms);
        }
    }

    // Set tcp no-delay
    if (options.nodelay) {
        if (is_linux) {
            try set(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, 1);
        }
    }

    try set(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, 1);
    try posix.bind(fd, &address.any, address.getOsSockLen());

    // Resolve port 0 to an actual port picked by the OS.
    var address_resolved: std.net.Address = .{ .any = undefined };
    var addrlen: posix.socklen_t = @sizeOf(std.net.Address);
    try posix.getsockname(fd, &address_resolved.any, &addrlen);
    assert(address_resolved.getOsSockLen() == addrlen);
    assert(address_resolved.any.family == address.any.family);

    try posix.listen(fd, options.backlog);

    return address_resolved;
}
