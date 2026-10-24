//! State of the `/status` panel: the rows it shows, built from
//! `StatusSnapshot.panelRows` when it opens, and how far they are scrolled.
//! The panel lives in the footer and writes nothing to the transcript.

const std = @import("std");
const output_contracts = @import("../output/output_contracts.zig");
const types = @import("../shared/types.zig");

pub const Row = output_contracts.StatusSnapshot.PanelRow;

/// What the panel's rows depend on that changes with no keystroke while it
/// is open: a running turn that saves the session or ends. The rows are
/// rebuilt when these differ from the ones they were built from.
pub const Facts = struct {
    history_turns: usize = 0,
    /// Null when the shell has no session.
    session_saved: ?bool = null,
};

/// The panel's rows and what they were built from. Owns everything.
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    rows: []const Row,
    facts: Facts,
    /// The credential the profile settings select, read once at open so a
    /// rebuild reads no file.
    preferred: ?types.CredentialSource,
    /// Why the settings could not be read at open, an error name.
    settings_error: ?[]const u8,

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const State = struct {
    active: bool = false,
    /// The first panel line shown when they do not all fit.
    scroll: usize = 0,
    snapshot: ?Snapshot = null,

    /// Takes ownership of `snapshot`.
    pub fn open(self: *State, snapshot: Snapshot) void {
        self.close();
        self.* = .{ .active = true, .snapshot = snapshot };
    }

    /// Replaces the rows and keeps the scroll position. Takes ownership of
    /// `snapshot`.
    pub fn replace(self: *State, snapshot: Snapshot) void {
        if (self.snapshot) |*old| old.deinit();
        self.snapshot = snapshot;
    }

    pub fn close(self: *State) void {
        if (self.snapshot) |*old| old.deinit();
        self.* = .{};
    }

    pub fn rows(self: *const State) []const Row {
        return if (self.snapshot) |*snapshot| snapshot.rows else &.{};
    }

    /// ↑↓ when the panel's `total_lines` do not fit its `visible_lines`.
    /// Returns whether the panel moved.
    pub fn scrollBy(self: *State, delta: i32, total_lines: usize, visible_lines: usize) bool {
        if (!self.active or delta == 0) return false;
        const last_start = total_lines -| @max(visible_lines, 1);
        const start = @min(self.scroll, last_start);
        const next = if (delta > 0) @min(start +| 1, last_start) else start -| 1;
        if (next == self.scroll) return false;
        self.scroll = next;
        return true;
    }
};
