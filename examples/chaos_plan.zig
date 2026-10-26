//! Bounded logical action plan shared by virtual replay and public UDP chaos.
//! The seed controls roles, application updates and protocol PRNGs. It cannot
//! make TLS randomness, ephemeral ports or host scheduling deterministic.
const std = @import("std");
pub const default_seed: u64 = 0x514d45534804;
pub const replay_seeds = [_]u64{ default_seed, 0x719e0023, 0xfedcba9876543210 };
pub const Action = enum {
    bootstrap,
    partition,
    expire_hints,
    suspect_gate,
    dead_gate,
    restart_application,
    heal,
    snapshot_repair,
    stale_endpoint,
    wrong_identity,
    moved_endpoint_repair,
    fresh_mesh_owner,
    final_repair,
};
pub const actions = std.meta.tags(Action);
pub const Plan = struct {
    seed: u64,
    probe_owner: u8,
    decoy_owner: u8,
    reset_owner: u8,
    updates: u8,
    noise: u8,
    replica_order: [3]u8,
    mesh_seeds: [4]u64,

    pub fn fingerprint(self: Plan) u64 {
        var out: u64 = 0xcbf29ce484222325;
        hashInt(&out, self.seed);
        for ([_]u8{ self.probe_owner, self.decoy_owner, self.reset_owner, self.updates, self.noise }) |n| hashInt(&out, n);
        for (self.replica_order) |n| hashInt(&out, n);
        for (self.mesh_seeds) |n| hashInt(&out, n);
        for (actions) |action| hashInt(&out, @backingInt(action));
        return out;
    }
};
pub fn generate(seed: u64) Plan {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var plan: Plan = .{
        .seed = seed,
        .probe_owner = 1 + random.uintLessThan(u8, 3),
        .decoy_owner = 1 + random.uintLessThan(u8, 3),
        .reset_owner = 1 + random.uintLessThan(u8, 3),
        .updates = 40 + random.uintLessThan(u8, 8),
        .noise = 40 + random.uintLessThan(u8, 8),
        .replica_order = .{ 1, 2, 3 },
        .mesh_seeds = undefined,
    };
    random.shuffle(u8, &plan.replica_order);
    for (&plan.mesh_seeds) |*value| value.* = random.int(u64);
    return plan;
}
pub fn hashInt(hash: *u64, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .big);
    hashBytes(hash, &bytes);
}
pub fn hashBytes(hash: *u64, bytes: []const u8) void {
    for (bytes) |byte| hash.* = (hash.* ^ byte) *% 0x100000001b3;
}
pub fn bytesFingerprint(bytes: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    hashBytes(&hash, bytes);
    return hash;
}
test "seeded logical plans reproduce roles, actions and update bounds" {
    for (replay_seeds) |seed| {
        const plan = generate(seed);
        try std.testing.expectEqualDeep(plan, generate(seed));
        try std.testing.expect(plan.updates >= 40 and plan.updates <= 47);
        try std.testing.expect(plan.noise >= 40 and plan.noise <= 47);
        for ([_]u8{ plan.probe_owner, plan.decoy_owner, plan.reset_owner }) |owner| try std.testing.expect(owner >= 1 and owner <= 3);
        var seen: [3]bool = @splat(false);
        for (plan.replica_order) |owner| {
            try std.testing.expect(owner >= 1 and owner <= 3);
            try std.testing.expect(!seen[owner - 1]);
            seen[owner - 1] = true;
        }
    }
}
test "different recorded seeds explore different logical plans" {
    try std.testing.expect(generate(replay_seeds[0]).fingerprint() != generate(replay_seeds[1]).fingerprint());
    try std.testing.expect(generate(replay_seeds[1]).fingerprint() != generate(replay_seeds[2]).fingerprint());
}
