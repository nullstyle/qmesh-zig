//! The simulated world: nodes + virtual network + virtual sessions +
//! the deterministic run loop, plus the fault-injection levers.
//!
//! Determinism contract:
//!
//! * One event heap keyed by (time, seq) — total order.
//! * Per-node PRNGs (seed derived from world seed + node index) and a
//!   dedicated link-loss PRNG; no global randomness.
//! * Node timers vs. events at the same timestamp: timers first, lowest
//!   node index first.
//! * Same seed ⇒ same run, byte for byte (see the determinism test).
//!
//! Fault injection available today:
//!
//!   world.policy.drop_bp = 500;          // 5% datagram loss
//!   world.pause(node, 10_000_000);       // freeze a node for 10 s
//!   world.kill(node);                    // permanent, sessions severed
//!   world.partition(&.{ 1, 2 }, &.{ 3, 4 });
//!   world.heal();
//!
//! Pause semantics: the node's local clock freezes (its protocol
//! deadlines shift forward), inbound traffic to it is dropped (both
//! classes — modeling a wedged event loop losing rcvbufs), sessions
//! stay established. Kill semantics: permanent; established sessions
//! to survivors are severed with notifications; in-flight messages
//! still deliver.
//!
//! The `World` value must be address-stable once nodes are spawned
//! (each node's transport holds a `*World`): declare it as a `var` and
//! never copy it.

const std = @import("std");
const qmesh = @import("qmesh");
const net = @import("network.zig");
const sessions_mod = @import("sessions.zig");
const sim_node = @import("node.zig");

const PeerId = qmesh.PeerId;
const PeerDesc = qmesh.PeerDesc;
const Addr = qmesh.Addr;
const NodeId = net.NodeId;
const Network = net.Network;
const Policy = net.Policy;
const Sessions = sessions_mod.Sessions;
const SimNode = sim_node.SimNode;
const SimTransport = sim_node.SimTransport;

pub const OneWayDrop = struct { from: NodeId, to: NodeId };

pub const WorldStats = struct {
    delivered: u64 = 0,
    dropped_loss: u64 = 0,
    dropped_partition: u64 = 0,
    dropped_dead: u64 = 0,
    dropped_paused: u64 = 0,
    dropped_no_session: u64 = 0,
    dials: u64 = 0,
    sessions_up: u64 = 0,
    sessions_down: u64 = 0,
};

pub const World = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    seed: u64,
    overlay_cfg: qmesh.OverlayConfig,
    swim_cfg: qmesh.swim.Config,
    broadcast_cfg: qmesh.plumtree.Config,
    policy: Policy,

    now_us: u64 = 0,

    nodes: std.ArrayListUnmanaged(*SimNode) = .empty,
    descs: std.ArrayListUnmanaged(PeerDesc) = .empty,
    index: std.AutoHashMapUnmanaged(PeerId, NodeId) = .empty,
    alive: std.ArrayListUnmanaged(bool) = .empty,

    paused_since: std.ArrayListUnmanaged(?u64) = .empty,
    paused_for: std.ArrayListUnmanaged(u64) = .empty,
    paused_total: std.ArrayListUnmanaged(u64) = .empty,

    prngs: std.ArrayListUnmanaged(std.Random.DefaultPrng) = .empty,
    net_rng: std.Random.DefaultPrng,
    scen_rng: std.Random.DefaultPrng,

    groups: std.ArrayListUnmanaged(u8) = .empty,
    blocked_pair: ?[2]u8 = null,
    /// One-directional blackholes (src→dst dropped, reverse flows).
    /// The brief's "asymmetric connectivity" fault.
    one_way_drops: std.ArrayListUnmanaged(OneWayDrop) = .empty,

    network: Network,
    sessions: Sessions,
    stats: WorldStats = .{},

    /// Per-node broadcast delivery logs (assertion surface for
    /// scenarios; production embedders bring their own hooks).
    logs: std.ArrayListUnmanaged(*DeliveryLog) = .empty,

    /// Scratch for nodeActiveIds; not part of world state.
    active_ids_scratch: std.ArrayListUnmanaged(PeerId) = .empty,

    pub fn init(allocator: std.mem.Allocator, seed: u64, overlay_cfg: qmesh.OverlayConfig, swim_cfg: qmesh.swim.Config, broadcast_cfg: qmesh.plumtree.Config, policy: Policy) Self {
        var s1 = std.Random.SplitMix64.init(seed ^ 0x1234_5678_9abc_def1);
        var s2 = std.Random.SplitMix64.init(seed ^ 0x0fed_cba9_8765_4321);
        return .{
            .allocator = allocator,
            .seed = seed,
            .overlay_cfg = overlay_cfg,
            .swim_cfg = swim_cfg,
            .broadcast_cfg = broadcast_cfg,
            .policy = policy,
            .net_rng = std.Random.DefaultPrng.init(s1.next()),
            .scen_rng = std.Random.DefaultPrng.init(s2.next()),
            .network = Network.init(allocator),
            .sessions = Sessions.init(allocator),
        };
    }

    pub fn deinit(w: *Self) void {
        for (w.nodes.items) |sn| {
            w.allocator.destroy(sn);
        }
        for (w.logs.items) |log| {
            log.items.deinit(w.allocator);
            w.allocator.destroy(log);
        }
        w.logs.deinit(w.allocator);
        w.nodes.deinit(w.allocator);
        w.descs.deinit(w.allocator);
        w.index.deinit(w.allocator);
        w.alive.deinit(w.allocator);
        w.paused_since.deinit(w.allocator);
        w.paused_for.deinit(w.allocator);
        w.paused_total.deinit(w.allocator);
        w.prngs.deinit(w.allocator);
        w.groups.deinit(w.allocator);
        w.one_way_drops.deinit(w.allocator);
        w.network.deinit();
        w.sessions.deinit();
        w.active_ids_scratch.deinit(w.allocator);
    }

    // --- node lifecycle ---------------------------------------------------

    pub fn spawn(w: *Self) !NodeId {
        const idx: NodeId = @intCast(w.nodes.items.len);
        var sm = std.Random.SplitMix64.init(w.seed ^ (@as(u64, idx) *% 0x9e37_79b9_7f4a_7c15) ^ 0xd1b54a32_d192ed03);
        const id = PeerId.fromRandom(w.scen_rng.random());
        const desc = PeerDesc{ .id = id, .addr = Addr.sim(idx) };

        // Per-node bookkeeping first: Node.init consults the clock
        // (transport.now → localNow → paused_since[idx]), so the arrays
        // must be sized before the node exists.
        try w.descs.append(w.allocator, desc);
        try w.index.put(w.allocator, id, idx);
        try w.alive.append(w.allocator, true);
        try w.paused_since.append(w.allocator, null);
        try w.paused_for.append(w.allocator, 0);
        try w.paused_total.append(w.allocator, 0);
        try w.prngs.append(w.allocator, std.Random.DefaultPrng.init(sm.next()));
        try w.groups.append(w.allocator, 0);

        const sn = try w.allocator.create(SimNode);
        errdefer w.allocator.destroy(sn);
        sn.* = .{
            .transport = .{ .world = w, .idx = idx },
            .node = undefined,
        };
        // Per-node delivery log, fed by the node's broadcast hook.
        const log = try w.allocator.create(DeliveryLog);
        errdefer w.allocator.destroy(log);
        log.* = .{ .allocator = w.allocator };
        try w.logs.append(w.allocator, log);

        sn.node = qmesh.node.Node(SimTransport).init(
            desc,
            .{ .overlay = w.overlay_cfg, .swim = w.swim_cfg, .broadcast = w.broadcast_cfg },
            &sn.transport,
            .{ .ctx = log, .onBroadcast = DeliveryLog.onBroadcast },
        );

        try w.nodes.append(w.allocator, sn);
        return idx;
    }

    pub fn kill(w: *Self, node: NodeId) !void {
        if (!w.alive.items[node]) return;
        w.alive.items[node] = false;
        // Close out any active pause so inspection stays consistent.
        if (w.paused_since.items[node]) |since| {
            w.paused_total.items[node] += w.now_us - since;
            w.paused_since.items[node] = null;
        }
        try w.sessions.killNode(w, node);
    }

    /// Freeze a node's local clock for `duration_us`; inbound traffic
    /// drops while frozen.
    pub fn pause(w: *Self, node: NodeId, duration_us: u64) !void {
        if (!w.alive.items[node]) return;
        if (w.paused_since.items[node] != null) return; // already paused
        w.paused_since.items[node] = w.now_us;
        w.paused_for.items[node] = duration_us;
        try w.network.schedule(w.now_us + duration_us, .{ .unpause = .{ .node = node } });
    }

    /// Every spawned node except `contact` starts a join through it.
    pub fn bootstrapAll(w: *Self, contact: NodeId) void {
        const contact_desc = w.descs.items[contact];
        for (w.nodes.items, 0..) |sn, i| {
            if (i == contact) continue;
            sn.node.startJoin(contact_desc);
        }
    }

    // --- partition ----------------------------------------------------------

    /// Split the listed nodes into two groups (1 and 2), block traffic
    /// between the groups, and sever existing cross-sessions. Unlisted
    /// nodes stay in group 0 (reachable from both sides).
    pub fn partition(w: *Self, side_a: []const NodeId, side_b: []const NodeId) !void {
        for (side_a) |n| w.groups.items[n] = 1;
        for (side_b) |n| w.groups.items[n] = 2;
        w.blocked_pair = .{ 1, 2 };
        try w.sessions.severBlocked(w);
    }

    pub fn heal(w: *Self) void {
        w.blocked_pair = null;
        w.one_way_drops.clearRetainingCapacity();
    }

    /// Drop all traffic from `from` to `to` (reverse flows unaffected).
    pub fn blackholeOneWay(w: *Self, from: NodeId, to: NodeId) !void {
        try w.one_way_drops.append(w.allocator, .{ .from = from, .to = to });
    }

    fn oneWayBlocked(w: *Self, from: NodeId, to: NodeId) bool {
        for (w.one_way_drops.items) |d| {
            if (d.from == from and d.to == to) return true;
        }
        return false;
    }

    pub fn blocked(w: *Self, a: NodeId, b: NodeId) bool {
        const ga = w.groups.items[a];
        const gb = w.groups.items[b];
        if (ga == gb) return false;
        if (w.blocked_pair) |bp| {
            return (ga == bp[0] and gb == bp[1]) or (ga == bp[1] and gb == bp[0]);
        }
        return false;
    }

    // --- clocks ---------------------------------------------------------------

    pub fn localNow(w: *Self, idx: NodeId) u64 {
        const global = w.paused_since.items[idx] orelse w.now_us;
        return global -| w.paused_total.items[idx];
    }

    /// Convert a node-local deadline to world time (adds accumulated
    /// pause and, while paused, the remaining pause duration).
    pub fn toGlobal(w: *Self, idx: NodeId, local: u64) u64 {
        var g = local + w.paused_total.items[idx];
        if (w.paused_since.items[idx] != null) g += w.paused_for.items[idx];
        return g;
    }

    pub fn nodeRng(w: *Self, idx: NodeId) std.Random {
        return w.prngs.items[idx].random();
    }

    // --- transport entry points (called by SimTransport / Sessions) -------------

    /// Apply loss/delay policy and enqueue a delivery.
    pub fn sendMessage(w: *Self, src: NodeId, dst: NodeId, bytes: []const u8, reliable: bool) !void {
        const copy = try w.allocator.dupe(u8, bytes);
        if (w.oneWayBlocked(src, dst) or w.blocked(src, dst)) {
            w.stats.dropped_partition += 1;
            w.allocator.free(copy);
            return;
        }
        const bp: u32 = if (reliable) w.policy.reliable_drop_bp else w.policy.drop_bp;
        if (bp > 0) {
            const draw = w.net_rng.random().uintLessThan(u32, 10_000);
            if (draw < bp) {
                w.stats.dropped_loss += 1;
                w.allocator.free(copy);
                return;
            }
        }
        const delay = if (w.policy.delay_max_us <= w.policy.delay_min_us)
            w.policy.delay_min_us
        else
            w.net_rng.random().intRangeAtMost(u64, w.policy.delay_min_us, w.policy.delay_max_us);
        try w.network.schedule(w.now_us + delay, .{ .deliver = .{
            .src = src,
            .dst = dst,
            .bytes = copy,
            .reliable = reliable,
        } });
    }

    /// Start (or confirm) a virtual dial.
    pub fn dial(w: *Self, a: NodeId, b: NodeId) !void {
        w.stats.dials += 1;
        if (!w.alive.items[a] or !w.alive.items[b]) return;
        if (w.paused_since.items[a] != null or w.paused_since.items[b] != null) return;
        if (w.blocked(a, b)) return;
        try w.sessions.ensure(w, a, b);
    }

    // --- run loop ---------------------------------------------------------------

    pub fn runFor(w: *Self, duration_us: u64) !void {
        try w.runUntil(w.now_us + duration_us);
    }

    /// Advance virtual time to `until`, processing every event and node
    /// timer in deterministic total order along the way.
    pub fn runUntil(w: *Self, until: u64) !void {
        // Standing guard: virtual time must keep flowing. If a stale
        // protocol deadline pins the clock, dump the world and stop
        // instead of spinning forever.
        var stall_iters: u64 = 0;
        var last_now: u64 = w.now_us;
        while (w.now_us < until) {
            stall_iters += 1;
            if (stall_iters > 200_000) {
                if (w.now_us == last_now) {
                    std.debug.print("CLOCK STALL at now={d} until={d}\n", .{ w.now_us, until });
                    for (w.nodes.items, 0..) |sn, i| {
                        var sus_dl: ?u64 = null;
                        for (sn.node.swim.memberSlice()) |m| {
                            if (m.state == .suspect) {
                                const d = m.state_since_us + sn.node.swim.scaledSuspicionTimeout();
                                if (sus_dl == null or d < sus_dl.?) sus_dl = d;
                            }
                        }
                        std.debug.print("  node {d} ovl={any} swim={any} bcast={any} probe_dl={any} phase={any} sus_dl={any} probe_target_known={}\n", .{ i, sn.node.overlay.nextDeadline(), sn.node.swim.nextDeadline(), sn.node.broadcast.nextDeadline(), if (sn.node.swim.probe) |p| p.deadline_us else null, if (sn.node.swim.probe) |p| @tagName(p.phase) else null, sus_dl, true });
                    }
                    @panic("runUntil clock stall");
                }
                stall_iters = 0;
                last_now = w.now_us;
            }
            // Earliest node timer (world time), timers-first tie-break,
            // lowest index first.
            var best_idx: ?NodeId = null;
            var best_at: u64 = 0;
            for (w.nodes.items, 0..) |sn, i| {
                if (!w.alive.items[i]) continue;
                if (w.paused_since.items[i] != null) continue;
                const nd = sn.node.nextDeadline() orelse continue;
                const g = w.toGlobal(@intCast(i), nd);
                if (best_idx == null or g < best_at) {
                    best_idx = @intCast(i);
                    best_at = g;
                }
            }
            const ev = w.network.peek();

            if (best_idx == null and ev == null) {
                break; // nothing left to do; jump the clock below
            }
            const timer_first = best_idx != null and (ev == null or best_at <= ev.?.at);
            if (timer_first) {
                if (best_at >= until) break;
                // Standing invariant: virtual time never runs backward
                // (a stale protocol deadline must not rewind the clock).
                w.now_us = @max(w.now_us, best_at);
                w.nodes.items[best_idx.?].node.tick();
            } else {
                if (ev.?.at > until) break;
                const e = w.network.pop().?;
                w.now_us = e.at;
                try w.dispatch(e);
            }
        }
        w.now_us = until;
    }

    fn dispatch(w: *Self, e: net.Event) !void {
        switch (e.kind) {
            .deliver => |d| {
                defer w.allocator.free(d.bytes);
                if (!w.alive.items[d.dst]) {
                    w.stats.dropped_dead += 1;
                    return;
                }
                if (w.paused_since.items[d.dst] != null) {
                    w.stats.dropped_paused += 1;
                    return;
                }
                if (w.blocked(d.src, d.dst)) {
                    w.stats.dropped_partition += 1;
                    return;
                }
                // Reliable traffic implies a live session end-to-end; if
                // the session died mid-flight the stream died with it.
                if (d.reliable and !w.sessions.establishedPair(d.src, d.dst)) {
                    w.stats.dropped_no_session += 1;
                    return;
                }
                w.nodes.items[d.dst].node.handleWire(w.descs.items[d.src].id, d.bytes);
                w.stats.delivered += 1;
            },
            .session_up => |su| {
                const rec = w.sessions.find(su.a, su.b) orelse return; // stale dial
                if (rec.state != .connecting) return;
                if (!w.alive.items[su.a] or !w.alive.items[su.b]) {
                    w.sessions.removePair(su.a, su.b);
                    return;
                }
                if (w.blocked(su.a, su.b)) {
                    w.sessions.removePair(su.a, su.b);
                    return;
                }
                rec.state = .established;
                w.stats.sessions_up += 1;
                w.nodes.items[su.a].node.onSessionUp(w.descs.items[su.b].id);
                w.nodes.items[su.b].node.onSessionUp(w.descs.items[su.a].id);
            },
            .session_down => |sd| {
                w.sessions.removePair(sd.a, sd.b);
                w.stats.sessions_down += 1;
                if (w.alive.items[sd.a]) w.nodes.items[sd.a].node.onSessionDown(w.descs.items[sd.b].id);
                if (w.alive.items[sd.b]) w.nodes.items[sd.b].node.onSessionDown(w.descs.items[sd.a].id);
            },
            .unpause => |r| {
                if (w.paused_since.items[r.node]) |since| {
                    w.paused_total.items[r.node] += w.now_us - since;
                    w.paused_since.items[r.node] = null;
                }
            },
        }
    }

    // --- introspection & scenario assertions ---------------------------------------

    pub fn liveNodes(w: *Self) usize {
        var n: usize = 0;
        for (w.alive.items) |a| {
            if (a) n += 1;
        }
        return n;
    }

    /// Every active-view entry of every live node must be backed by an
    /// established session — the core overlay/transport invariant.
    pub fn activeEdgesSessionBacked(w: *Self) bool {
        for (w.nodes.items, 0..) |sn, i| {
            if (!w.alive.items[i]) continue;
            for (sn.node.overlay.activeSlice()) |e| {
                const other = w.index.get(e.desc.id) orelse return false;
                if (!w.sessions.establishedPair(@intCast(i), other)) return false;
            }
        }
        return true;
    }

    /// Undirected overlay connectivity: number of connected components
    /// over live nodes, where an edge exists if either endpoint lists
    /// the other as active.
    pub fn componentCount(w: *Self) usize {
        const n = w.nodes.items.len;
        var seen = std.AutoHashMapUnmanaged(NodeId, void){};
        defer seen.deinit(w.allocator);
        var components: usize = 0;
        var queue: std.ArrayListUnmanaged(NodeId) = .empty;
        defer queue.deinit(w.allocator);

        var start: NodeId = 0;
        while (start < n) : (start += 1) {
            if (!w.alive.items[start]) continue;
            if (seen.contains(start)) continue;
            components += 1;
            queue.clearRetainingCapacity();
            queue.append(w.allocator, start) catch return components;
            seen.put(w.allocator, start, {}) catch return components;
            while (queue.pop()) |cur| {
                // neighbors: cur's actives + anyone listing cur
                for (w.nodes.items[cur].node.overlay.activeSlice()) |e| {
                    const other = w.index.get(e.desc.id) orelse continue;
                    if (!w.alive.items[other]) continue;
                    if (!seen.contains(other)) {
                        seen.put(w.allocator, other, {}) catch return components;
                        queue.append(w.allocator, other) catch return components;
                    }
                }
                for (w.nodes.items, 0..) |sn2, j| {
                    const jj: NodeId = @intCast(j);
                    if (!w.alive.items[jj]) continue;
                    if (seen.contains(jj)) continue;
                    for (sn2.node.overlay.activeSlice()) |e| {
                        if (w.index.get(e.desc.id)) |listed| {
                            if (listed == cur) {
                                seen.put(w.allocator, jj, {}) catch return components;
                                queue.append(w.allocator, jj) catch return components;
                                break;
                            }
                        }
                    }
                }
            }
        }
        return components;
    }

    /// Minimum active-view size across live nodes (usize maxInt when
    /// no live nodes).
    pub fn minActiveView(w: *Self) usize {
        var m: usize = std.math.maxInt(usize);
        for (w.nodes.items, 0..) |sn, i| {
            if (!w.alive.items[i]) continue;
            m = @min(m, sn.node.overlay.activeSlice().len);
        }
        return m;
    }

    pub fn nodeActiveIds(w: *Self, idx: NodeId) []const PeerId {
        const sn = w.nodes.items[idx];
        w.active_ids_scratch.clearRetainingCapacity();
        for (sn.node.overlay.activeSlice()) |e| {
            w.active_ids_scratch.append(w.allocator, e.desc.id) catch return w.active_ids_scratch.items;
        }
        std.mem.sort(PeerId, w.active_ids_scratch.items, {}, peerIdLess);
        return w.active_ids_scratch.items;
    }

    /// Publish a broadcast from node `idx`.
    pub fn broadcast(w: *Self, idx: NodeId, payload: []const u8) ?qmesh.plumtree.MsgId {
        return w.nodes.items[idx].node.publish(payload);
    }

    /// How many broadcasts node `idx` has delivered so far.
    pub fn deliveredCount(w: *Self, idx: NodeId) usize {
        return w.logs.items[idx].items.items.len;
    }

    /// Delivered broadcast seqs (from one origin), sorted — repair
    /// delivery order is not publication order.
    pub fn deliveredSeqs(w: *Self, idx: NodeId) []const u64 {
        const log = w.logs.items[idx];
        for (log.items.items, 0..) |*it, i| {
            log.seq_scratch[i] = it.seq;
        }
        const out = log.seq_scratch[0..log.items.items.len];
        std.mem.sort(u64, out, {}, std.sort.asc(u64));
        return out;
    }

    /// Sum of broadcast eager-set sizes (tree-shape metric).
    pub fn totalEagerEdges(w: *Self) usize {
        var n: usize = 0;
        for (w.nodes.items, 0..) |sn, i| {
            if (w.alive.items[i]) n += sn.node.broadcast.eagerSlice().len;
        }
        return n;
    }

    pub fn totalDemotions(w: *Self) u64 {
        var n: u64 = 0;
        for (w.nodes.items, 0..) |sn, i| {
            if (w.alive.items[i]) n += sn.node.broadcast.stats.demotions;
        }
        return n;
    }

    /// Deterministic fingerprint of the whole world's overlay state —
    /// equal runs produce equal fingerprints.
    pub fn fingerprint(w: *Self) u64 {
        var h: u64 = 0x9e3779b97f4a7c15;
        for (w.nodes.items, 0..) |_, i| {
            if (!w.alive.items[i]) {
                h = h *% 31 +% 0xdead;
                continue;
            }
            h = h *% 31 +% @as(u64, i);
            for (w.nodeActiveIds(@intCast(i))) |id| {
                for (id.bytes) |b| h = h *% 131 +% b;
            }
        }
        return h;
    }
};

fn peerIdLess(_: void, a: PeerId, b: PeerId) bool {
    return std.mem.order(u8, &a.bytes, &b.bytes) == .lt;
}

/// Scenario-facing broadcast delivery record: identity + payload
/// head (payloads are call-scoped at delivery time, so we keep a
/// bounded copy).
pub const DeliveryLog = struct {
    const Collected = struct {
        origin: PeerId,
        seq: u64,
        len: usize,
        head: [32]u8 = @splat(0),
    };

    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(Collected) = .empty,
    seq_scratch: [1024]u64 = undefined,

    fn onBroadcast(ctx: ?*anyopaque, origin: PeerId, seq: u64, payload: []const u8) void {
        const log: *DeliveryLog = @ptrCast(@alignCast(ctx.?));
        var rec = Collected{
            .origin = origin,
            .seq = seq,
            .len = payload.len,
        };
        const n = @min(payload.len, rec.head.len);
        @memcpy(rec.head[0..n], payload[0..n]);
        log.items.append(log.allocator, rec) catch {};
    }
};
