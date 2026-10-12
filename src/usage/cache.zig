//! The shared usage cache: one file per identity under `~/.fx/usage-cache/`.
//! Every fx process reads it without a lock (writes land by rename) and
//! writes it under an exclusive lock as read, merge, write, rename, so a
//! newer answer is never replaced by an older one (`CacheNeverRegresses`).

const std = @import("std");
const report = @import("report.zig");
const codex = @import("codex.zig");
const grok = @import("grok.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const dir_name = "usage-cache";
pub const schema_version: u32 = 2;
const max_file_bytes: usize = 4 * 1024 * 1024;

/// Whose numbers an entry holds: SHA-256, in hex, of the sign-in kind, a
/// stable subject (the API key, or the fx login account) and the team. The
/// subject never reaches the file.
pub const Identity = [64]u8;

pub fn identityOf(scope: report.Scope, subject: []const u8, team: []const u8) Identity {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx-usage-cache-v1\x00");
    hash.update(@tagName(scope));
    hash.update("\x00");
    hash.update(subject);
    hash.update("\x00");
    hash.update(team);
    return std.fmt.bytesToHex(hash.finalResult(), .lower);
}

/// Today's per-model numbers, from a fetch that started at `at_ms`.
pub const Today = struct {
    day: i64,
    at_ms: i64,
    models: []const report.ModelRow,
};

/// The finished days before `day`: the 7d window's and this calendar
/// month's (empty on the 1st).
pub const Finished = struct {
    day: i64,
    at_ms: i64,
    days_7: []const report.ModelRow,
    month: []const report.ModelRow,
};

pub const Budget = struct {
    at_ms: i64,
    value: report.Budget,
};

/// A ChatGPT plan's limits through Codex, from a fetch that started at `at_ms`.
pub const Codex = struct {
    at_ms: i64,
    value: codex.Usage,
};

/// A Grok plan's allowance and credits, from a fetch that started at `at_ms`.
pub const Grok = struct {
    at_ms: i64,
    value: grok.Usage,
};

pub const Entry = struct {
    today: ?Today = null,
    finished: ?Finished = null,
    budget: ?Budget = null,
    codex: ?Codex = null,
    grok: ?Grok = null,
};

/// An entry and the arena that owns its slices.
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    entry: Entry,

    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
    }
};

/// Combines what was stored with what a fetch returned. Each part keeps the
/// newer of the two: today by fetch start, finished days by day, the budget
/// by fetch start. The result borrows from both inputs.
pub fn merge(stored: Entry, fetched: Entry) Entry {
    return .{
        .today = newer(Today, stored.today, fetched.today, todayKey),
        .finished = newer(Finished, stored.finished, fetched.finished, finishedKey),
        .budget = newer(Budget, stored.budget, fetched.budget, budgetKey),
        .codex = mergeCodex(stored.codex, fetched.codex),
        .grok = mergeGrok(stored.grok, fetched.grok),
    };
}

/// The newer billing; a fetch whose settings request failed keeps the
/// stored plan name.
fn mergeGrok(stored: ?Grok, fetched: ?Grok) ?Grok {
    var result = newer(Grok, stored, fetched, grokKey) orelse return null;
    if (stored) |s| if (result.value.settings == null) {
        result.value.settings = s.value.settings;
    };
    return result;
}

fn grokKey(g: Grok) i64 {
    return g.at_ms;
}

/// The newer limits; a fetch whose activity or breakdown request failed
/// keeps what is already stored.
fn mergeCodex(stored: ?Codex, fetched: ?Codex) ?Codex {
    var result = newer(Codex, stored, fetched, codexKey) orelse return null;
    if (stored) |s| {
        if (result.value.profile == null) result.value.profile = s.value.profile;
        if (result.value.breakdown == null) result.value.breakdown = s.value.breakdown;
    }
    return result;
}

fn codexKey(c: Codex) i64 {
    return c.at_ms;
}

fn todayKey(t: Today) i64 {
    return t.at_ms;
}

fn finishedKey(f: Finished) i64 {
    return f.day;
}

fn budgetKey(b: Budget) i64 {
    return b.at_ms;
}

fn newer(comptime T: type, stored: ?T, fetched: ?T, key: fn (T) i64) ?T {
    const s = stored orelse return fetched;
    const f = fetched orelse return s;
    return if (key(f) >= key(s)) f else s;
}

const Wire = struct {
    schema_version: u32,
    identity: []const u8,
    today: ?Today = null,
    finished: ?Finished = null,
    budget: ?Budget = null,
    codex: ?Codex = null,
    grok: ?Grok = null,
};

pub fn encode(alloc: Allocator, identity: Identity, entry: Entry) ![]u8 {
    var out: Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(Wire{
        .schema_version = schema_version,
        .identity = &identity,
        .today = entry.today,
        .finished = entry.finished,
        .budget = entry.budget,
        .codex = entry.codex,
        .grok = entry.grok,
    }, .{}, &out.writer);
    return out.toOwnedSlice();
}

/// Parses a cache file for `identity`. Anything malformed, from another
/// schema, or for another identity reads as absent. The result copies every
/// string, so `bytes` may be freed right after.
pub fn decode(gpa: Allocator, identity: Identity, bytes: []const u8) ?Owned {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const wire = std.json.parseFromSliceLeaky(Wire, arena.allocator(), bytes, .{ .allocate = .alloc_always }) catch {
        arena.deinit();
        return null;
    };
    if (wire.schema_version != schema_version or
        !std.mem.eql(u8, wire.identity, &identity) or
        !validEntry(.{ .today = wire.today, .finished = wire.finished, .budget = wire.budget, .codex = wire.codex, .grok = wire.grok }))
    {
        arena.deinit();
        return null;
    }
    return .{ .arena = arena, .entry = .{ .today = wire.today, .finished = wire.finished, .budget = wire.budget, .codex = wire.codex, .grok = wire.grok } };
}

fn validRows(rows: []const report.ModelRow) bool {
    if (rows.len > report.max_models) return false;
    for (rows) |row| {
        if (row.model.len == 0 or row.model.len > 256) return false;
        if (!row.totals.valid()) return false;
    }
    return true;
}

fn validMoney(value: f64) bool {
    return std.math.isFinite(value) and value >= 0;
}

fn validEntry(entry: Entry) bool {
    if (entry.today) |t| if (!validRows(t.models)) return false;
    if (entry.finished) |f| if (!validRows(f.days_7) or !validRows(f.month)) return false;
    if (entry.budget) |b| if (!validMoney(b.value.limit) or !validMoney(b.value.spent)) return false;
    if (entry.codex) |c| if (!c.value.valid()) return false;
    if (entry.grok) |g| if (!g.value.valid()) return false;
    return true;
}

fn fileName(buf: *[80]u8, identity: Identity, suffix: []const u8) []const u8 {
    return std.mem.print(buf, "{s}{s}", .{ &identity, suffix }) catch unreachable;
}

/// Reads the stored entry for `identity` from `fx_dir` (`~/.fx`), or null.
pub fn read(gpa: Allocator, io: Io, fx_dir: Io.Dir, identity: Identity) ?Owned {
    var dir = fx_dir.openDir(io, dir_name, .{}) catch return null;
    defer dir.close(io);
    var name_buf: [80]u8 = undefined;
    const bytes = dir.readFileAlloc(io, fileName(&name_buf, identity, ".json"), gpa, .limited(max_file_bytes)) catch return null;
    defer gpa.free(bytes);
    return decode(gpa, identity, bytes);
}

/// Merges `fetched` into the stored entry under the identity's lock and
/// writes the result by rename. Returns the merged entry. Caller owns it.
pub fn store(gpa: Allocator, io: Io, fx_dir: Io.Dir, identity: Identity, fetched: Entry) !Owned {
    fx_dir.createDir(io, dir_name, .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var dir = try fx_dir.openDir(io, dir_name, .{});
    defer dir.close(io);

    var name_buf: [80]u8 = undefined;
    var lock = try dir.createFile(io, fileName(&name_buf, identity, ".lock"), .{
        .truncate = false,
        .lock = .exclusive,
        .permissions = .fromMode(0o600),
    });
    defer lock.close(io);

    var stored = read(gpa, io, fx_dir, identity);
    defer if (stored) |*s| s.deinit();
    const merged = merge(if (stored) |s| s.entry else .{}, fetched);

    const bytes = try encode(gpa, identity, merged);
    defer gpa.free(bytes);
    var tmp_buf: [80]u8 = undefined;
    const tmp_name = fileName(&tmp_buf, identity, ".tmp");
    try dir.writeFile(io, .{ .sub_path = tmp_name, .data = bytes, .flags = .{ .permissions = .fromMode(0o600) } });
    try dir.rename(tmp_name, dir, fileName(&name_buf, identity, ".json"), io);

    return decode(gpa, identity, bytes) orelse error.InvalidCache;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn oneRow(comptime cost: f64) []const report.ModelRow {
    return &.{.{ .model = "anthropic/claude-opus-5.5", .totals = .{ .request_count = 2, .total_cost = cost } }};
}

test "merge keeps the newer part of each half" {
    const old: Entry = .{
        .today = .{ .day = 10, .at_ms = 200, .models = oneRow(2) },
        .finished = .{ .day = 10, .at_ms = 100, .days_7 = oneRow(7), .month = oneRow(30) },
        .budget = .{ .at_ms = 200, .value = .{ .limit = 100, .spent = 5, .period = .monthly } },
    };
    // An older fetch arrives late: nothing of it may replace newer data.
    const late = merge(old, .{ .today = .{ .day = 10, .at_ms = 150, .models = oneRow(1) } });
    try testing.expectEqual(@as(i64, 200), late.today.?.at_ms);
    try testing.expectEqual(@as(f64, 7), late.finished.?.days_7[0].totals.total_cost);
    // A newer fetch with only today keeps the stored finished days and budget.
    const fresh = merge(old, .{ .today = .{ .day = 10, .at_ms = 300, .models = oneRow(3) } });
    try testing.expectEqual(@as(f64, 3), fresh.today.?.models[0].totals.total_cost);
    try testing.expectEqual(@as(i64, 10), fresh.finished.?.day);
    try testing.expectEqual(@as(f64, 5), fresh.budget.?.value.spent);
}

test "the cache file round-trips and rejects other identities" {
    const a = identityOf(.member, "acct_1", "team_1");
    const b = identityOf(.api_key, "acct_1", "team_1");
    try testing.expect(!std.mem.eql(u8, &a, &b));
    const entry: Entry = .{
        .today = .{ .day = 20737, .at_ms = 1, .models = oneRow(1.5) },
        .budget = .{ .at_ms = 1, .value = .{ .limit = 31600, .spent = 6596.55, .period = .monthly } },
    };
    const bytes = try encode(testing.allocator, a, entry);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.find(u8, bytes, "acct_1") == null);
    var decoded = decode(testing.allocator, a, bytes).?;
    defer decoded.deinit();
    try testing.expectEqualStrings("anthropic/claude-opus-5.5", decoded.entry.today.?.models[0].model);
    try testing.expectEqual(report.RefreshPeriod.monthly, decoded.entry.budget.?.value.period);
    try testing.expect(decode(testing.allocator, b, bytes) == null);
    try testing.expect(decode(testing.allocator, a, "{\"schema_version\":2}") == null);
    try testing.expect(decode(testing.allocator, a, "garbage") == null);
}

test "a decoded entry outlives the bytes it came from" {
    const id = identityOf(.api_key, "k", "");
    const encoded = try encode(testing.allocator, id, .{ .today = .{ .day = 1, .at_ms = 1, .models = oneRow(1) } });
    var decoded = decode(testing.allocator, id, encoded).?;
    defer decoded.deinit();
    @memset(encoded, 'x');
    testing.allocator.free(encoded);
    try testing.expectEqualStrings("anthropic/claude-opus-5.5", decoded.entry.today.?.models[0].model);
}

test "store merges under the lock and never regresses today" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const id = identityOf(.member, "acct_1", "team_1");
    var first = try store(testing.allocator, io, tmp.dir, id, .{
        .today = .{ .day = 5, .at_ms = 500, .models = oneRow(5) },
        .finished = .{ .day = 5, .at_ms = 500, .days_7 = oneRow(7), .month = oneRow(30) },
    });
    first.deinit();
    var second = try store(testing.allocator, io, tmp.dir, id, .{
        .today = .{ .day = 5, .at_ms = 400, .models = oneRow(4) },
    });
    defer second.deinit();
    try testing.expectEqual(@as(i64, 500), second.entry.today.?.at_ms);
    try testing.expectEqual(@as(i64, 5), second.entry.finished.?.day);
    var again = read(testing.allocator, io, tmp.dir, id).?;
    defer again.deinit();
    try testing.expectEqual(@as(f64, 5), again.entry.today.?.models[0].totals.total_cost);
}
