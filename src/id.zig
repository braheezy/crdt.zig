const std = @import("std");

pub const ActorId = [16]u8;
pub const OpId = struct {
    actor: ActorId,
    counter: u64,

    pub fn eql(self: OpId, other: OpId) bool {
        return std.mem.eql(u8, &self.actor, &other.actor) and self.counter == other.counter;
    }

    pub fn order(self: OpId, other: OpId) std.math.Order {
        if (std.mem.eql(u8, &self.actor, &other.actor)) {
            return if (self.counter < other.counter) .lt else if (self.counter == other.counter) .eq else .gt;
        } else {
            return std.mem.order(u8, &self.actor, &other.actor);
        }
    }
};

fn actorWithLastByte(last_byte: u8) ActorId {
    var actor = [_]u8{0} ** 16;
    actor[15] = last_byte;
    return actor;
}

fn isLessThanOrEqual(order: std.math.Order) bool {
    return order == .lt or order == .eq;
}

test "OpId equality requires the same actor and counter" {
    const actor_a = actorWithLastByte(1);
    const actor_b = actorWithLastByte(2);

    const original = OpId{ .actor = actor_a, .counter = 42 };
    const identical = OpId{ .actor = actor_a, .counter = 42 };
    const different_counter = OpId{ .actor = actor_a, .counter = 43 };
    const different_actor = OpId{ .actor = actor_b, .counter = 42 };

    try std.testing.expect(OpId.eql(original, identical));
    try std.testing.expect(!OpId.eql(original, different_counter));
    try std.testing.expect(!OpId.eql(original, different_actor));
}

test "OpId orders counters within one actor" {
    const actor = actorWithLastByte(1);
    const earlier = OpId{ .actor = actor, .counter = 0 };
    const later = OpId{ .actor = actor, .counter = 1 };

    try std.testing.expectEqual(std.math.Order.lt, OpId.order(earlier, later));
    try std.testing.expectEqual(std.math.Order.gt, OpId.order(later, earlier));
    try std.testing.expectEqual(std.math.Order.eq, OpId.order(earlier, earlier));
}

test "OpId orders actors lexicographically before counters" {
    var lower_actor = actorWithLastByte(0xff);
    lower_actor[0] = 0x00;

    var higher_actor = actorWithLastByte(0x00);
    higher_actor[0] = 0x01;

    const lower = OpId{ .actor = lower_actor, .counter = std.math.maxInt(u64) };
    const higher = OpId{ .actor = higher_actor, .counter = 0 };

    try std.testing.expectEqual(std.math.Order.lt, OpId.order(lower, higher));
    try std.testing.expectEqual(std.math.Order.gt, OpId.order(higher, lower));
}

test "OpId ordering is antisymmetric and transitive" {
    const actor_a = actorWithLastByte(1);
    const actor_b = actorWithLastByte(2);
    const ids = [_]OpId{
        .{ .actor = actor_a, .counter = 0 },
        .{ .actor = actor_a, .counter = 1 },
        .{ .actor = actor_b, .counter = 0 },
        .{ .actor = actor_b, .counter = 1 },
    };

    for (ids) |left| {
        for (ids) |right| {
            const forward = OpId.order(left, right);
            const reverse = OpId.order(right, left);

            switch (forward) {
                .lt => try std.testing.expectEqual(std.math.Order.gt, reverse),
                .eq => try std.testing.expectEqual(std.math.Order.eq, reverse),
                .gt => try std.testing.expectEqual(std.math.Order.lt, reverse),
            }
        }
    }

    for (ids) |first| {
        for (ids) |second| {
            for (ids) |third| {
                const first_to_second = OpId.order(first, second);
                const second_to_third = OpId.order(second, third);

                if (isLessThanOrEqual(first_to_second) and isLessThanOrEqual(second_to_third)) {
                    try std.testing.expect(isLessThanOrEqual(OpId.order(first, third)));
                }
            }
        }
    }
}
