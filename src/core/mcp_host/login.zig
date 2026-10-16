//! The loopback redirect for an MCP sign-in (RFC 8252 §7.3): fx listens on
//! 127.0.0.1, the browser comes back to `GET /callback`, and the address it
//! came to goes to MCP-v2's `finishSignIn`. A bridged sign-in (Slack's,
//! through fx.sh) comes back instead as a form its page posts.
//!
//! fx's browser callback reader reads the requests, so a connection that
//! stays silent, as a browser's spare one does, is dropped and the next one
//! served. Only a return carrying this sign-in's state ends the wait
//!: anything else, such as a request for an icon or a return with
//! another state, gets a 404 and the wait goes on.
//!
//! TLA+ model: `tests/tla/mcp_host/SignIn.tla`.

const std = @import("std");
const browser_callback = @import("../auth/browser_callback.zig");

const Allocator = std.mem.Allocator;

/// A sign-in whose redirect is a page elsewhere: it posts what came back to
/// it as a form here, from `origin`. Both borrowed.
pub const Bridge = struct {
    origin: []const u8,
    /// The redirect MCP-v2 signs in with; the form's fields become its query.
    redirect: []const u8,
};

/// The reader's own cancellation; a login's wait is cancelled through `io`.
var never_canceled: std.atomic.Value(bool) = .init(false);

pub const Listener = struct {
    server: std.Io.net.Server,
    port: u16,
    bridge: ?Bridge = null,
    /// The sign-in's state, from its authorization address (`expect`).
    /// Until it comes, every return is someone else's.
    state: struct {
        mutex: std.Io.Mutex = .init,
        buf: [64]u8 = undefined,
        len: usize = 0,
    } = .{},

    /// Listens on 127.0.0.1 at `port`, or at a free port when null.
    pub fn open(io: std.Io, port: ?u16) !Listener {
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port orelse 0);
        var server = try address.listen(io, .{ .reuse_address = port != null });
        return .{ .port = server.socket.address.getPort(), .server = server };
    }

    pub fn close(l: *Listener, io: std.Io) void {
        l.server.deinit(io);
    }

    /// The redirect URI to sign in with, in `buffer`.
    pub fn redirectUri(l: *const Listener, buffer: *[64]u8) []const u8 {
        if (l.bridge) |b| return b.redirect;
        const origin = "http://127.0.0.1:";
        const path = "/callback";
        comptime std.debug.assert(origin.len + std.fmt.count("{d}", .{std.math.maxInt(@TypeOf(l.port))}) + path.len <= buffer.len);
        buffer[0..origin.len].* = origin.*;
        const port_end = origin.len + std.fmt.printInt(buffer[origin.len..], l.port, 10, .lower, .{});
        buffer[port_end..][0..path.len].* = path.*;
        return buffer[0 .. port_end + path.len];
    }

    /// Takes the sign-in's state from `authorize`, its authorization address.
    /// Safe while `accept` waits on another thread.
    pub fn expect(l: *Listener, io: std.Io, authorize: []const u8) void {
        const query_at = std.mem.findScalar(u8, authorize, '?') orelse return;
        const state = param(authorize[query_at + 1 ..], "state") orelse return;
        if (state.len > l.state.buf.len) return;
        l.state.mutex.lockUncancelable(io);
        defer l.state.mutex.unlock(io);
        @memcpy(l.state.buf[0..state.len], state);
        l.state.len = state.len;
    }

    /// Whether `fields`, a query or a form, carry the sign-in's state.
    fn isOwn(l: *Listener, io: std.Io, fields: []const u8) bool {
        const state = param(fields, "state") orelse return false;
        l.state.mutex.lockUncancelable(io);
        defer l.state.mutex.unlock(io);
        return l.state.len != 0 and std.mem.eql(u8, state, l.state.buf[0..l.state.len]);
    }

    /// Waits for the browser's return of this sign-in and returns the full
    /// address it came to, owned by `alloc`. A cancellation point: cancelling
    /// the task ends the wait with error.Canceled within one poll.
    pub fn accept(l: *Listener, io: std.Io, alloc: Allocator) ![]u8 {
        var waiting: Waiting = .{ .listener = l, .io = io };
        while (true) {
            try io.checkCancel();
            const taken = if (l.bridge) |b|
                try browser_callback.await_form(Return, takeForm, alloc, &l.server, &waiting, null, null, b.origin)
            else
                try browser_callback.await(Return, takeReturn, alloc, &l.server, &waiting, &never_canceled, null);
            var got = taken orelse continue;
            defer got.deinit();
            got.respond(if (got.callback.refused) .failed else .ok) catch {};
            return got.callback.url;
        }
    }
};

const Waiting = struct { listener: *Listener, io: std.Io };

/// The browser's return: the address for MCP-v2, and whether it refused.
const Return = struct { url: []u8, refused: bool };

/// `GET /callback` with the sign-in's state; anything else is unrelated.
fn takeReturn(context: ?*anyopaque, alloc: Allocator, target: []const u8) browser_callback.ParseResult(Return) {
    const w: *Waiting = @ptrCast(@alignCast(context.?));
    const query_at = std.mem.findScalar(u8, target, '?') orelse return .unrelated;
    const query = target[query_at + 1 ..];
    if (!std.mem.eql(u8, target[0..query_at], "/callback") or !w.listener.isOwn(w.io, query)) return .unrelated;
    const url = alloc.print("http://127.0.0.1:{d}{s}", .{ w.listener.port, target }) catch |err| return .{ .failed = err };
    // A refusal comes back with an `error` (RFC 6749 §4.1.2.1); MCP-v2 reads
    // the rest from the address.
    return .{ .accepted = .{ .url = url, .refused = hasParam(query, "error") } };
}

/// A bridge's form with the sign-in's state: its fields become the query of
/// the redirect MCP-v2 signed in with. The reader checked the rest.
fn takeForm(context: ?*anyopaque, alloc: Allocator, form: []const u8) browser_callback.ParseResult(Return) {
    const w: *Waiting = @ptrCast(@alignCast(context.?));
    if (!w.listener.isOwn(w.io, form)) return .unrelated;
    const url = alloc.print("{s}?{s}", .{ w.listener.bridge.?.redirect, form }) catch |err| return .{ .failed = err };
    return .{ .accepted = .{ .url = url, .refused = hasParam(form, "error") } };
}

/// The raw value of the parameter `name` in `query`, if it has one.
fn param(query: []const u8, name: []const u8) ?[]const u8 {
    var params = std.mem.splitScalar(u8, query, '&');
    while (params.next()) |p| {
        const eq = std.mem.findScalar(u8, p, '=') orelse p.len;
        if (std.mem.eql(u8, p[0..eq], name)) return if (eq < p.len) p[eq + 1 ..] else "";
    }
    return null;
}

fn hasParam(query: []const u8, name: []const u8) bool {
    return param(query, name) != null;
}

const testing = std.testing;

fn connect(port: u16) !std.Io.net.Stream {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    return address.connect(testing.io, .{ .mode = .stream });
}

/// The reply, as much of it as fits in `out`. It gives up after 5 s without
/// a byte: a listener that stopped taking returns fails the test instead of
/// hanging it.
fn readReply(stream: std.Io.net.Stream, out: []u8) []const u8 {
    var in: [512]u8 = undefined;
    var reader = stream.reader(testing.io, &in);
    var n: usize = 0;
    while (n < out.len) {
        if (reader.interface.bufferedLen() == 0) {
            var fds = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            if ((std.posix.poll(&fds, 5000) catch 0) == 0) break;
        }
        const got = reader.interface.readSliceShort(out[n..]) catch break;
        if (got == 0) break;
        n += got;
    }
    return out[0..n];
}

/// Sends one GET and returns the reply, as much of it as fits in `out`.
fn get(port: u16, target: []const u8, out: []u8) ![]const u8 {
    const stream = try connect(port);
    defer stream.close(testing.io);
    var request: [512]u8 = undefined;
    var writer = stream.writer(testing.io, &request);
    try writer.interface.print("GET {s} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", .{target});
    try writer.interface.flush();
    return readReply(stream, out);
}

/// The authorization address of a sign-in whose state is `s1`.
const authorize_s1 = "https://as.example/authorize?response_type=code&client_id=c&state=s1&code_challenge=x";

test "the return of this sign-in is the callback address; other requests and returns get a 404 and the wait goes on" {
    var listener = try Listener.open(testing.io, null);
    defer listener.close(testing.io);
    try testing.expect(listener.port != 0);
    var buffer: [64]u8 = undefined;
    const uri = listener.redirectUri(&buffer);
    try testing.expect(std.mem.startsWith(u8, uri, "http://127.0.0.1:"));
    try testing.expect(std.mem.endsWith(u8, uri, "/callback"));
    listener.expect(testing.io, authorize_s1);

    const Browser = struct {
        replies: [4][4096]u8 = undefined,
        reply: [4][]const u8 = .{ "", "", "", "" },
        fn run(b: *@This(), port: u16) void {
            const targets = [_][]const u8{ "/favicon.ico", "/callback?code=c0&state=s2", "/callback?code=c0", "/callback?code=c1&state=s1" };
            for (targets, 0..) |target, i| b.reply[i] = get(port, target, &b.replies[i]) catch "";
        }
    };
    var browser: Browser = .{};
    const thread = try std.Thread.spawn(.{}, Browser.run, .{ &browser, listener.port });
    const url = listener.accept(testing.io, testing.allocator) catch |err| {
        thread.join();
        return err;
    };
    thread.join();
    defer testing.allocator.free(url);
    const want = try testing.allocator.print("http://127.0.0.1:{d}/callback?code=c1&state=s1", .{listener.port});
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, url);
    for (browser.reply[0..3]) |reply| try testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 404"));
    try testing.expect(std.mem.startsWith(u8, browser.reply[3], "HTTP/1.1 200 OK"));
    try testing.expect(std.mem.find(u8, browser.reply[3], "Authorization complete") != null);
}

test "a return before the sign-in's state is known is a 404" {
    var listener = try Listener.open(testing.io, null);
    defer listener.close(testing.io);
    const Browser = struct {
        listener: *Listener,
        early: [4096]u8 = undefined,
        early_reply: []const u8 = "",
        page: [4096]u8 = undefined,
        page_reply: []const u8 = "",
        fn run(b: *@This()) void {
            b.early_reply = get(b.listener.port, "/callback?code=c1&state=s1", &b.early) catch "";
            // As `.authorize` does on the owner thread while the wait goes on.
            b.listener.expect(testing.io, authorize_s1);
            b.page_reply = get(b.listener.port, "/callback?code=c1&state=s1", &b.page) catch "";
        }
    };
    var browser: Browser = .{ .listener = &listener };
    const thread = try std.Thread.spawn(.{}, Browser.run, .{&browser});
    const url = listener.accept(testing.io, testing.allocator) catch |err| {
        thread.join();
        return err;
    };
    thread.join();
    testing.allocator.free(url);
    try testing.expect(std.mem.startsWith(u8, browser.early_reply, "HTTP/1.1 404"));
    try testing.expect(std.mem.startsWith(u8, browser.page_reply, "HTTP/1.1 200 OK"));
}

test "a silent connection, like a browser's spare one, doesn't hold up the return" {
    var listener = try Listener.open(testing.io, null);
    defer listener.close(testing.io);
    listener.expect(testing.io, authorize_s1);
    const Browser = struct {
        page: [4096]u8 = undefined,
        reply: []const u8 = "",
        fn spare(port: u16) void {
            const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return;
            const stream = address.connect(testing.io, .{ .mode = .stream }) catch return;
            defer stream.close(testing.io);
            std.Io.sleep(testing.io, .fromMilliseconds(2000), .awake) catch {};
        }
        fn run(b: *@This(), port: u16) void {
            std.Io.sleep(testing.io, .fromMilliseconds(100), .awake) catch {};
            b.reply = get(port, "/callback?code=c1&state=s1", &b.page) catch "";
        }
    };
    var browser: Browser = .{};
    const started_ms = std.Io.Clock.awake.now(testing.io).toMilliseconds();
    const spare = try std.Thread.spawn(.{}, Browser.spare, .{listener.port});
    defer spare.join();
    const thread = try std.Thread.spawn(.{}, Browser.run, .{ &browser, listener.port });
    const url = listener.accept(testing.io, testing.allocator) catch |err| {
        thread.join();
        return err;
    };
    const took_ms = std.Io.Clock.awake.now(testing.io).toMilliseconds() - started_ms;
    thread.join();
    testing.allocator.free(url);
    try testing.expect(std.mem.startsWith(u8, browser.reply, "HTTP/1.1 200 OK"));
    // Taken while the spare connection is still open, not after it closes.
    try testing.expect(took_ms < 1000);
}

/// Sends one form POST from `origin` and returns the reply, as much as fits in `out`.
fn post(port: u16, origin: []const u8, body: []const u8, out: []u8) ![]const u8 {
    const stream = try connect(port);
    defer stream.close(testing.io);
    var request: [1024]u8 = undefined;
    var writer = stream.writer(testing.io, &request);
    try writer.interface.print("POST /slack/oauth/callback HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nOrigin: {s}\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}", .{ port, origin, body.len, body });
    try writer.interface.flush();
    return readReply(stream, out);
}

test "a bridge's form from its origin with the sign-in's state is the callback; anything else is a 404" {
    var listener = try Listener.open(testing.io, null);
    defer listener.close(testing.io);
    listener.bridge = .{ .origin = "https://fx.sh", .redirect = "https://fx.sh/api/slack/oauth/callback" };
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("https://fx.sh/api/slack/oauth/callback", listener.redirectUri(&buffer));
    listener.expect(testing.io, authorize_s1);
    const Page = struct {
        bad: [4096]u8 = undefined,
        bad_reply: []const u8 = "",
        good: [4096]u8 = undefined,
        good_reply: []const u8 = "",
        stray: [4096]u8 = undefined,
        stray_reply: []const u8 = "",
        fn run(b: *@This(), port: u16) void {
            b.bad_reply = post(port, "https://evil.example", "state=s1&code=c1", &b.bad) catch "";
            b.stray_reply = post(port, "https://fx.sh", "state=s2&code=c0", &b.stray) catch "";
            b.good_reply = post(port, "https://fx.sh", "state=s1&code=c1", &b.good) catch "";
        }
    };
    var page: Page = .{};
    const thread = try std.Thread.spawn(.{}, Page.run, .{ &page, listener.port });
    const url = listener.accept(testing.io, testing.allocator) catch |err| {
        thread.join();
        return err;
    };
    thread.join();
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("https://fx.sh/api/slack/oauth/callback?state=s1&code=c1", url);
    try testing.expect(std.mem.startsWith(u8, page.bad_reply, "HTTP/1.1 404"));
    try testing.expect(std.mem.startsWith(u8, page.stray_reply, "HTTP/1.1 404"));
    try testing.expect(std.mem.startsWith(u8, page.good_reply, "HTTP/1.1 200 OK"));
}

test "a refused sign-in comes back to the failure page; someone else's refusal is a 404" {
    var listener = try Listener.open(testing.io, null);
    defer listener.close(testing.io);
    listener.expect(testing.io, authorize_s1);
    const Browser = struct {
        stray: [4096]u8 = undefined,
        stray_reply: []const u8 = "",
        page: [4096]u8 = undefined,
        reply: []const u8 = "",
        fn run(b: *@This(), port: u16) void {
            b.stray_reply = get(port, "/callback?error=access_denied&state=s2", &b.stray) catch "";
            b.reply = get(port, "/callback?error=access_denied&state=s1", &b.page) catch "";
        }
    };
    var browser: Browser = .{};
    const thread = try std.Thread.spawn(.{}, Browser.run, .{ &browser, listener.port });
    const url = listener.accept(testing.io, testing.allocator) catch |err| {
        thread.join();
        return err;
    };
    thread.join();
    testing.allocator.free(url);
    try testing.expect(std.mem.startsWith(u8, browser.stray_reply, "HTTP/1.1 404"));
    try testing.expect(std.mem.startsWith(u8, browser.reply, "HTTP/1.1 400"));
    try testing.expect(std.mem.find(u8, browser.reply, "Authorization failed") != null);
}

test "the redirect URI spells out every port in full" {
    var buffer: [64]u8 = undefined;
    for ([_]struct { u16, []const u8 }{
        .{ 1, "http://127.0.0.1:1/callback" },
        .{ 8080, "http://127.0.0.1:8080/callback" },
        .{ 65535, "http://127.0.0.1:65535/callback" },
    }) |case| {
        const listener: Listener = .{ .server = undefined, .port = case[0] };
        try testing.expectEqualStrings(case[1], listener.redirectUri(&buffer));
    }
}
