const std = @import("std");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const host_stream = @import("host_stream_provider.zig");
const builtin_gateway = @import("../builtins/gateway.zig");
const Allocator = std.mem.Allocator;

const max_catalog_bytes = 4 * 1024 * 1024;

/// Borrows the host transport for the lifetime of the provider.
pub fn provider(transport: *host_stream.Transport) model_catalog.Provider {
    return .{ .context = transport, .fetch_fn = fetch };
}

fn fetch(raw: ?*anyopaque, alloc: Allocator, input: model_catalog.FetchInput) Allocator.Error!model_catalog.ProviderResult {
    const transport: *host_stream.Transport = @ptrCast(@alignCast(raw.?));
    const url = try std.fmt.allocPrint(alloc, "{s}{s}", .{ builtin_gateway.default_model_catalog_base_url, input.endpoint });
    defer alloc.free(url);
    const auth = if (input.access.authorizationCredential()) |credential| try std.fmt.allocPrint(alloc, "Bearer {s}", .{credential}) else null;
    defer if (auth) |value| alloc.free(value);
    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(alloc);
    if (auth) |value| try headers.append(alloc, .{ .name = "authorization", .value = value });
    if (input.access.teamContext()) |team| try headers.append(alloc, .{ .name = "x-vercel-ai-gateway-team", .value = team });
    const body = switch (try get(alloc, transport.*, url, headers.items, input.cancel_flag, max_catalog_bytes)) {
        .body => |body| body,
        .failure => |failure| return .{ .failure = failure },
    };
    defer alloc.free(body);
    const catalog = builtin_gateway.parseModelCatalogForView(alloc, body, input.view) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .malformed_response } };
    };
    return .{ .catalog = catalog };
}

pub const GetResult = union(enum) {
    /// Owned by the caller.
    body: []u8,
    failure: model_catalog.Failure,
};

/// Sends one GET through the host and reads a 200 response body of at most
/// `max_bytes`. Other statuses map to catalog failures.
pub fn get(
    alloc: Allocator,
    transport: host_stream.Transport,
    url: []const u8,
    headers: []const std.http.Header,
    cancel_flag: ?*std.atomic.Value(bool),
    max_bytes: usize,
) Allocator.Error!GetResult {
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    std.json.Stringify.value(headers, .{}, &encoded.writer) catch return error.OutOfMemory;
    if (cancelled(cancel_flag)) return .{ .failure = .{ .category = .cancellation } };
    const handle = transport.open_fn(transport.context, "GET", url, encoded.written(), "") catch return .{ .failure = .{ .category = .transport } };
    if (handle < 0) return .{ .failure = .{ .category = .transport } };
    defer transport.close_fn(transport.context, handle);
    var status: u16 = 0;
    while (true) {
        if (cancelled(cancel_flag)) return .{ .failure = .{ .category = .cancellation } };
        const state = transport.status_fn(transport.context, handle, &status);
        if (state == 1) break;
        if (state < 0) return .{ .failure = .{ .category = if (state == -2) .cancellation else .transport } };
    }
    if (status != 200) return .{ .failure = model_catalog.failureForHttpStatus(@enumFromInt(status)) };
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        if (cancelled(cancel_flag)) return .{ .failure = .{ .category = .cancellation } };
        const count = transport.next_fn(transport.context, handle, &chunk);
        if (count == -3) continue;
        if (count < 0) return .{ .failure = .{ .category = if (count == -2) .cancellation else .transport } };
        if (count == 0) break;
        const size: usize = @intCast(count);
        if (size > chunk.len or size > max_bytes -| body.items.len) return .{ .failure = .{ .category = .resource_exhausted } };
        try body.appendSlice(alloc, chunk[0..size]);
    }
    return .{ .body = try body.toOwnedSlice(alloc) };
}

fn cancelled(cancel_flag: ?*std.atomic.Value(bool)) bool {
    return if (cancel_flag) |flag| flag.load(.seq_cst) else false;
}
