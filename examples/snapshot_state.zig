//! Fixed, bounded application state. Hints announce a revision; only snapshots
//! carry values. This is an example wire schema, not a qmesh protocol.
const std = @import("std");
pub const value_count = 8;
pub const snapshot_bytes = 81;
pub const hint_bytes = 16;
const snapshot_magic = "QMSNAP01";
const hint_magic = "QMHINT01";

pub const State = struct {
    revision: u64 = 0,
    values: [value_count]u64 = @splat(0),

    pub fn update(self: *State) void {
        self.revision += 1;
        for (&self.values, 0..) |*value, i| value.* = self.revision * 100 + i;
    }

    pub fn encode(self: State) [snapshot_bytes]u8 {
        var out: [snapshot_bytes]u8 = undefined;
        @memcpy(out[0..8], snapshot_magic);
        std.mem.writeInt(u64, out[8..16], self.revision, .big);
        out[16] = value_count;
        for (self.values, 0..) |value, i| std.mem.writeInt(u64, out[17 + i * 8 ..][0..8], value, .big);
        return out;
    }

    pub fn decode(bytes: []const u8) !State {
        if (bytes.len != snapshot_bytes) return error.InvalidSnapshotSize;
        if (!std.mem.eql(u8, bytes[0..8], snapshot_magic)) return error.UnsupportedSnapshotVersion;
        if (bytes[16] != value_count) return error.InvalidSnapshotShape;
        var out: State = .{ .revision = std.mem.readInt(u64, bytes[8..16], .big) };
        for (&out.values, 0..) |*value, i| value.* = std.mem.readInt(u64, bytes[17 + i * 8 ..][0..8], .big);
        return out;
    }

    /// Decode fully before changing state; delayed/duplicate snapshots cannot
    /// roll a replica back. A production multi-writer schema needs conflict policy.
    pub fn apply(self: *State, bytes: []const u8) !void {
        const incoming = try decode(bytes);
        if (incoming.revision <= self.revision) return error.StaleSnapshot;
        self.* = incoming;
    }
};

pub fn hint(revision: u64) [hint_bytes]u8 {
    var out: [hint_bytes]u8 = undefined;
    @memcpy(out[0..8], hint_magic);
    std.mem.writeInt(u64, out[8..16], revision, .big);
    return out;
}

pub fn hintRevision(bytes: []const u8) ?u64 {
    if (bytes.len != hint_bytes or !std.mem.eql(u8, bytes[0..8], hint_magic)) return null;
    return std.mem.readInt(u64, bytes[8..16], .big);
}

test "snapshot round trip and revision hint have fixed bounds" {
    var authority: State = .{};
    authority.update();
    const encoded = authority.encode();
    var replica: State = .{};
    try replica.apply(&encoded);
    try std.testing.expectEqualDeep(authority, replica);
    try std.testing.expectEqual(@as(?u64, 1), hintRevision(&hint(1)));
    try std.testing.expect(hintRevision("unrelated announcement") == null);
}

test "malformed snapshot cannot partially mutate application state" {
    var replica: State = .{};
    const before = replica;
    var bytes = replica.encode();
    try std.testing.expectError(error.InvalidSnapshotSize, replica.apply(bytes[0..80]));
    var oversized: [snapshot_bytes + 1]u8 = @splat(0);
    try std.testing.expectError(error.InvalidSnapshotSize, replica.apply(&oversized));
    bytes[7] = '2';
    try std.testing.expectError(error.UnsupportedSnapshotVersion, replica.apply(&bytes));
    bytes = replica.encode();
    bytes[16] = 9;
    try std.testing.expectError(error.InvalidSnapshotShape, replica.apply(&bytes));
    try std.testing.expectEqualDeep(before, replica);
}

test "stale and duplicate snapshots do not roll a replica back" {
    var authority: State = .{};
    authority.update();
    const old = authority.encode();
    authority.update();
    var replica: State = .{};
    try replica.apply(&authority.encode());
    try std.testing.expectError(error.StaleSnapshot, replica.apply(&old));
    try std.testing.expectError(error.StaleSnapshot, replica.apply(&authority.encode()));
    try std.testing.expectEqualDeep(authority, replica);
}
