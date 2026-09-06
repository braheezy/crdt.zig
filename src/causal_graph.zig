const std = @import("std");
const id = @import("id.zig");
const operation = @import("operation.zig");
const Frontier = @import("frontier.zig").Frontier;

const ActorId = id.ActorId;
const OpId = id.OpId;
const Operation = operation.Operation;

const Event = struct {
    id: OpId,
    operation: Operation = .{ .insert = .{} },
    parents: std.ArrayList(OpId) = .empty,

    pub fn init(_: std.mem.Allocator, op_id: OpId, parents: std.ArrayList(OpId)) !Event {
        var ev = Event{ .id = op_id };
        ev.parents = parents;
        return ev;
    }

    pub fn deinit(self: *Event, allocator: std.mem.Allocator) void {
        self.operation.deinit(allocator);
        self.parents.deinit(allocator);
    }
};

pub const CausalGraph = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(Event) = .empty,
    frontier: *Frontier,

    pub const Relation = enum {
        equal,
        ancestor,
        descendant,
        concurrent,
    };

    pub fn init(allocator: std.mem.Allocator) !*CausalGraph {
        const self = try allocator.create(CausalGraph);
        self.* = .{
            .allocator = allocator,
            .frontier = try Frontier.init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *CausalGraph) void {
        self.frontier.deinit();
        for (self.events.items) |*event| {
            event.deinit(self.allocator);
        }
        self.events.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn operation(self: *const CausalGraph, op_id: OpId) ?*const Operation {
        for (self.events.items) |event| {
            if (event.id.eql(op_id)) return &event.operation;
        }
        return null;
    }

    pub fn add(self: *CausalGraph, new_op: OpId, parents: []const OpId) !void {
        if (self.contains(new_op)) return;

        for (parents) |parent| {
            var found = false;
            for (self.events.items) |event| {
                if (event.id.eql(parent)) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.MissingParent;
        }

        var owned_parents: std.ArrayList(OpId) = .empty;
        try owned_parents.appendSlice(self.allocator, parents);
        const new_event = try Event.init(self.allocator, new_op, owned_parents);
        try self.events.append(self.allocator, new_event);
        try self.frontier.advance(parents, new_op);
    }

    pub fn addWithOperation(self: *CausalGraph, new_op: OpId, opr: Operation, parents: std.ArrayList(OpId)) !void {
        if (self.contains(new_op)) return;

        for (parents.items) |parent| {
            var found = false;
            for (self.events.items) |event| {
                if (event.id.eql(parent)) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.MissingParent;
        }

        var new_event = try Event.init(self.allocator, new_op, parents);
        new_event.operation = opr;
        try self.events.append(self.allocator, new_event);
        try self.frontier.advance(parents.items, new_op);
    }

    pub fn relation(self: *CausalGraph, op1: OpId, op2: OpId) !Relation {
        if (op1.eql(op2)) return .equal;

        _ = self.findEvent(op1) orelse return error.UnknownOperation;
        _ = self.findEvent(op2) orelse return error.UnknownOperation;

        if (try self.isAncestor(op1, op2)) return .ancestor;
        if (try self.isAncestor(op2, op1)) return .descendant;

        return .concurrent;
    }

    pub fn contains(self: *CausalGraph, this_op: OpId) bool {
        for (self.events.items) |event| {
            if (event.id.eql(this_op)) return true;
        }
        return false;
    }

    pub fn heads(self: *const CausalGraph) []const OpId {
        return self.frontier.heads.items;
    }

    fn isAncestor(self: *CausalGraph, ancestor: OpId, descendant: OpId) !bool {
        const desc_event = self.findEvent(descendant) orelse return error.UnknownOperation;

        var work = try desc_event.parents.clone(self.allocator);
        defer work.deinit(self.allocator);

        while (work.items.len > 0) {
            const candidate = work.pop() orelse unreachable;

            if (candidate.eql(ancestor)) return true;

            const candidate_event = self.findEvent(candidate) orelse return error.UnknownOperation;
            try work.appendSlice(self.allocator, candidate_event.parents.items);
        }
        return false;
    }

    fn findEvent(self: *CausalGraph, op_id: OpId) ?Event {
        for (self.events.items) |event| {
            if (event.id.eql(op_id)) return event;
        }
        return null;
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

fn expectHeads(graph: *const CausalGraph, expected: []const OpId) !void {
    const actual = graph.heads();
    try std.testing.expectEqual(expected.len, actual.len);

    for (expected, 0..) |expected_id, index| {
        try std.testing.expect(OpId.eql(expected_id, actual[index]));
    }
}

test "adding a genesis operation stores it and makes it a head" {
    var graph = try CausalGraph.init(std.testing.allocator);
    defer graph.deinit();

    const a0 = op(1, 0);
    try graph.add(a0, &.{});

    try std.testing.expect(graph.contains(a0));
    try expectHeads(graph, &.{a0});
}

test "a child replaces its known parent as the head" {
    var graph = try CausalGraph.init(std.testing.allocator);
    defer graph.deinit();

    const a0 = op(1, 0);
    const a1 = op(1, 1);

    try graph.add(a0, &.{});
    try graph.add(a1, &.{a0});

    try std.testing.expect(graph.contains(a0));
    try std.testing.expect(graph.contains(a1));
    try expectHeads(graph, &.{a1});
}

test "an operation with an unknown parent is rejected without changing the graph" {
    var graph = try CausalGraph.init(std.testing.allocator);
    defer graph.deinit();

    const missing_parent = op(1, 0);
    const child = op(2, 0);

    try std.testing.expectError(error.MissingParent, graph.add(child, &.{missing_parent}));
    try std.testing.expect(!graph.contains(child));
    try expectHeads(graph, &.{});
}

test "delivering the same operation twice is idempotent" {
    var graph = try CausalGraph.init(std.testing.allocator);
    defer graph.deinit();

    const a0 = op(1, 0);
    try graph.add(a0, &.{});
    try graph.add(a0, &.{});

    try expectHeads(graph, &.{a0});
}

test "concurrent branches produce two sorted heads" {
    var graph = try CausalGraph.init(std.testing.allocator);
    defer graph.deinit();

    const a0 = op(1, 0);
    const b0 = op(2, 0);

    // Both operations are independently based on the empty history.
    try graph.add(b0, &.{});
    try graph.add(a0, &.{});

    try expectHeads(graph, &.{ a0, b0 });
}

test "a merge operation replaces both branch heads" {
    var graph = try CausalGraph.init(std.testing.allocator);
    defer graph.deinit();

    const a0 = op(1, 0);
    const b0 = op(2, 0);
    const merge = op(3, 0);

    try graph.add(a0, &.{});
    try graph.add(b0, &.{});
    try graph.add(merge, &.{ a0, b0 });

    try expectHeads(graph, &.{merge});
}

test "an operation-aware add stores the text operation" {
    var graph = try CausalGraph.init(std.testing.allocator);
    defer graph.deinit();

    const edit = try Operation.initInsert(std.testing.allocator, 0, "hello");

    const a0 = op(1, 0);
    const owned_parents: std.ArrayList(OpId) = .empty;
    try graph.addWithOperation(a0, edit, owned_parents);

    const stored = graph.operation(a0) orelse return error.MissingOperation;
    switch (stored.*) {
        .insert => |insert| try std.testing.expectEqualStrings("hello", insert.text),
        .delete => return error.ExpectedInsert,
    }
}

test "causal relation identifies an operation and itself" {
    var graph = try CausalGraph.init(std.testing.allocator);
    defer graph.deinit();

    const a0 = op(1, 0);
    try graph.add(a0, &.{});

    try std.testing.expectEqual(CausalGraph.Relation.equal, try graph.relation(a0, a0));
}

test "causal relation identifies ancestors and descendants through the graph" {
    var graph = try CausalGraph.init(std.testing.allocator);
    defer graph.deinit();

    const a0 = op(1, 0);
    const a1 = op(1, 1);
    const a2 = op(1, 2);

    try graph.add(a0, &.{});
    try graph.add(a1, &.{a0});
    try graph.add(a2, &.{a1});

    try std.testing.expectEqual(CausalGraph.Relation.ancestor, try graph.relation(a0, a2));
    try std.testing.expectEqual(CausalGraph.Relation.descendant, try graph.relation(a2, a0));
}

test "causal relation identifies concurrent branches" {
    var graph = try CausalGraph.init(std.testing.allocator);
    defer graph.deinit();

    const root = op(1, 0);
    const left = op(2, 0);
    const right = op(3, 0);

    try graph.add(root, &.{});
    try graph.add(left, &.{root});
    try graph.add(right, &.{root});

    try std.testing.expectEqual(CausalGraph.Relation.concurrent, try graph.relation(left, right));
    try std.testing.expectEqual(CausalGraph.Relation.concurrent, try graph.relation(right, left));
}

test "causal relation rejects unknown operations" {
    var graph = try CausalGraph.init(std.testing.allocator);
    defer graph.deinit();

    const known = op(1, 0);
    const unknown = op(2, 0);
    try graph.add(known, &.{});

    try std.testing.expectError(error.UnknownOperation, graph.relation(known, unknown));
}
