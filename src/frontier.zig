const std = @import("std");
const id = @import("id.zig");

const ActorId = id.ActorId;
const OpId = id.OpId;

pub const Frontier = struct {
    allocator: std.mem.Allocator,
    heads: std.ArrayList(OpId) = .empty,

    pub fn init(allocator: std.mem.Allocator) !*Frontier {
        const self = try allocator.create(Frontier);
        self.* = .{
            .allocator = allocator,
        };
        return self;
    }
    pub fn deinit(self: *Frontier) void {
        self.heads.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn advance(self: *Frontier, parents: []const OpId, new_op: OpId) !void {
        for (parents) |parent| {
            var i: usize = 0;
            while (i < self.heads.items.len) {
                const head = self.heads.items[i];
                if (head.eql(parent)) {
                    _ = self.heads.orderedRemove(i);
                    break;
                } else {
                    i += 1;
                }
            }
        }

        var insert_index: usize = self.heads.items.len;
        for (self.heads.items, 0..) |head, i| {
            if (head.order(new_op) == .gt) {
                insert_index = i;
                break;
            }
        }
        try self.heads.insert(self.allocator, insert_index, new_op);
    }
};

fn actorWithLastByte(last_byte: u8) ActorId {
    var actor = [_]u8{0} ** 16;
    actor[15] = last_byte;
    return actor;
}

fn op(actor_last_byte: u8, counter: u64) OpId {
    return .{
        .actor = actorWithLastByte(actor_last_byte),
        .counter = counter,
    };
}

fn expectHeads(frontier: *const Frontier, expected: []const OpId) !void {
    const actual = frontier.heads.items;
    try std.testing.expectEqual(expected.len, actual.len);

    for (expected, 0..) |expected_id, index| {
        try std.testing.expect(OpId.eql(expected_id, actual[index]));
    }
}

test "a new operation becomes the first head of an empty frontier" {
    var frontier = try Frontier.init(std.testing.allocator);
    defer frontier.deinit();

    const a0 = op(1, 0);
    try frontier.advance(&.{}, a0);

    try expectHeads(frontier, &.{a0});
}

test "a sequential operation replaces its parent head" {
    var frontier = try Frontier.init(std.testing.allocator);
    defer frontier.deinit();

    const a0 = op(1, 0);
    const a1 = op(1, 1);

    try frontier.advance(&.{}, a0);
    try frontier.advance(&.{a0}, a1);

    try expectHeads(frontier, &.{a1});
}

test "a concurrent operation preserves unrelated heads and output stays sorted" {
    var frontier = try Frontier.init(std.testing.allocator);
    defer frontier.deinit();

    const a0 = op(1, 0);
    const b0 = op(2, 0);

    // Receive B's edit first, then A's concurrent edit. Neither has a parent.
    try frontier.advance(&.{}, b0);
    try frontier.advance(&.{}, a0);

    try expectHeads(frontier, &.{ a0, b0 });
}

test "an operation based on two concurrent heads replaces both heads" {
    var frontier = try Frontier.init(std.testing.allocator);
    defer frontier.deinit();

    const a0 = op(1, 0);
    const b0 = op(2, 0);
    const c0 = op(3, 0);

    try frontier.advance(&.{}, a0);
    try frontier.advance(&.{}, b0);
    try frontier.advance(&.{ a0, b0 }, c0);

    try expectHeads(frontier, &.{c0});
}

test "a late child of an old non-head does not remove the current head" {
    var frontier = try Frontier.init(std.testing.allocator);
    defer frontier.deinit();

    const a0 = op(1, 0);
    const b0 = op(2, 0);
    const c0 = op(3, 0);

    try frontier.advance(&.{}, a0);
    try frontier.advance(&.{a0}, b0);

    // C was authored from A:0 before B:0 was known, then arrived late.
    try frontier.advance(&.{a0}, c0);

    try expectHeads(frontier, &.{ b0, c0 });
}
