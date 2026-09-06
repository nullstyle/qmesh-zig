//! qmesh_sim — the deterministic in-process cluster simulator.
//!
//! A first-class consumer of qmesh (never the reverse): it drives the
//! same pure protocol cores the real QUIC transport will, through the
//! same `Node(Transport)` driver, so scenario results transfer.
//!
//! ```zig
//! var world = qsim.World.init(allocator, seed, .{}, .{});
//! defer world.deinit();
//! _ = try world.spawn(); // × N
//! world.bootstrapAll(0);
//! try world.runFor(30_000_000); // 30 s virtual
//! try std.testing.expect(world.componentCount() == 1);
//! ```

pub const network = @import("network.zig");
pub const sessions = @import("sessions.zig");
pub const node = @import("node.zig");
pub const world = @import("world.zig");

pub const World = world.World;
pub const Network = network.Network;
pub const Policy = network.Policy;
pub const NodeId = network.NodeId;
pub const SimNode = node.SimNode;
pub const SimTransport = node.SimTransport;

test {
    _ = network;
    _ = sessions;
    _ = node;
    _ = world;
}
