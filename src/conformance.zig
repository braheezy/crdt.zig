//! Generated semantic conformance fixtures.
//!
//! These tests generate real causal changes with several offline replicas,
//! deliver them in adversarial orders, and compare the production walker with
//! the independent Eg-walker/FugueMax model.  A green Replica suite alone
//! cannot catch two implementations that make the same ordering mistake; an
//! independent model can.

const std = @import("std");
const id = @import("id.zig");
const operation_module = @import("operation.zig");
const change_module = @import("change.zig");
const merge_module = @import("merge_index.zig");
const fugue_oracle = @import("fugue_oracle.zig");
const replica_module = @import("replica.zig");
const external_data = @import("external_conformance_options.zig");

const ActorId = id.ActorId;
const OpId = id.OpId;
const Operation = operation_module.Operation;
const Change = change_module.Change;
const Replica = replica_module.Replica;

const ExternalTransaction = struct {
    span: [2]usize,
    parents: []usize,
    agent: []const u8,
    seqStart: usize,
    ops: []std.json.Value,
};

const ExternalTrace = struct {
    txns: []ExternalTransaction,
    endContent: []const u8,
};

const Lcg = struct {
    state: u64,

    fn init(seed: u64) Lcg {
        return .{ .state = seed | 1 };
    }

    fn next(self: *Lcg) u64 {
        self.state = self.state *% 6364136223846793005 +% 1442695040888963407;
        return self.state;
    }
};

fn actor(last_byte: u8) ActorId {
    var value = [_]u8{0} ** 16;
    value[15] = last_byte;
    return value;
}

fn scalarCount(bytes: []const u8) usize {
    return std.unicode.utf8CountCodepoints(bytes) catch unreachable;
}

fn generateLocalEdits(replica: *Replica, random_state: *u64, edit_count: usize) !void {
    const snippets = [_][]const u8{ "a", "β", "XY", "🙂", "中" };
    var edit_index: usize = 0;
    while (edit_index < edit_count) : (edit_index += 1) {
        const visible = scalarCount(replica.textView());
        var rng = Lcg{ .state = random_state.* | 1 };
        const should_insert = visible == 0 or rng.next() % 3 != 0;
        if (should_insert) {
            const index = @as(usize, @intCast(rng.next() % (visible + 1)));
            const snippet = snippets[@as(usize, @intCast(rng.next() % snippets.len))];
            _ = try replica.insert(index, snippet);
        } else {
            const index = @as(usize, @intCast(rng.next() % visible));
            const length = @as(usize, @intCast(rng.next() % (visible - index))) + 1;
            _ = try replica.delete(index, length);
        }
        random_state.* = rng.state;
    }
}

fn changeExists(changes: []const Change, wanted: OpId) bool {
    for (changes) |change| if (change.id.eql(wanted)) return true;
    return false;
}

fn collectGeneratedChanges(allocator: std.mem.Allocator) !std.ArrayList(Change) {
    const actors = [_]ActorId{ actor(21), actor(22), actor(23), actor(24) };
    var sources: [4]*Replica = undefined;
    for (&sources, actors) |*slot, source_actor| slot.* = try Replica.init(allocator, source_actor);
    defer for (sources) |source| source.deinit();

    var result: std.ArrayList(Change) = .empty;
    errdefer {
        for (result.items) |change| change.deinit(allocator);
        result.deinit(allocator);
    }

    const root_id = try sources[0].insert(0, "base");
    var root = try sources[0].change(root_id, allocator);
    defer root.deinit(allocator);
    for (sources[1..]) |source| _ = try source.receive(&root);

    var root_copy = try root.clone(allocator);
    var root_moved = false;
    errdefer if (!root_moved) root_copy.deinit(allocator);
    try result.append(allocator, root_copy);
    root_moved = true;
    var random_state: u64 = 0x9e3779b97f4a7c15;
    for (sources) |source| try generateLocalEdits(source, &random_state, 24);

    // Bring the offline branches together once and author one operation from
    // the resulting multi-head frontier.  This gives the generated corpus a
    // real merge event rather than only independent chains.
    for (sources[1..]) |source| {
        var empty_for_source = replica_module.Version{};
        var branch = try source.changesSince(&empty_for_source, allocator);
        defer {
            for (branch.items) |change| change.deinit(allocator);
            branch.deinit(allocator);
        }
        for (branch.items) |*change| _ = try sources[0].receive(change);
    }
    _ = try sources[0].insert(scalarCount(sources[0].textView()), "merge");

    var empty = replica_module.Version{};
    for (sources) |source| {
        var batch = try source.changesSince(&empty, allocator);
        defer {
            for (batch.items) |change| change.deinit(allocator);
            batch.deinit(allocator);
        }
        for (batch.items) |change| {
            if (!changeExists(result.items, change.id)) {
                var cloned = try change.clone(allocator);
                var moved = false;
                errdefer if (!moved) cloned.deinit(allocator);
                try result.append(allocator, cloned);
                moved = true;
            }
        }
    }
    return result;
}

fn topologicalOrder(changes: []const Change, allocator: std.mem.Allocator) ![]usize {
    const order = try allocator.alloc(usize, changes.len);
    errdefer allocator.free(order);
    const done = try allocator.alloc(bool, changes.len);
    defer allocator.free(done);
    @memset(done, false);

    var completed: usize = 0;
    while (completed < changes.len) {
        var selected: ?usize = null;
        for (changes, 0..) |change, index| {
            if (done[index]) continue;
            var ready = true;
            for (change.parents.items) |parent| {
                var parent_index: ?usize = null;
                for (changes, 0..) |candidate, candidate_index| {
                    if (candidate.id.eql(parent)) {
                        parent_index = candidate_index;
                        break;
                    }
                }
                if (parent_index == null or !done[parent_index.?]) {
                    ready = false;
                    break;
                }
            }
            if (!ready) continue;
            if (selected == null or change.id.order(changes[selected.?].id) == .lt) selected = index;
        }
        const selected_index = selected orelse return error.CausalCycle;
        done[selected_index] = true;
        order[completed] = selected_index;
        completed += 1;
    }
    return order;
}

fn expectedForChanges(changes: []const Change, allocator: std.mem.Allocator) ![]u8 {
    const order = try topologicalOrder(changes, allocator);
    defer allocator.free(order);
    const events = try allocator.alloc(fugue_oracle.HistoryEvent, changes.len);
    defer allocator.free(events);
    for (changes, events) |change, *event| {
        event.* = .{
            .id = change.id,
            .parents = change.parents.items,
            .operation = switch (change.operation) {
                .insert => |insert_operation| .{ .insert = .{ .index = insert_operation.index, .text = insert_operation.text } },
                .delete => |delete_operation| .{ .delete = .{ .index = delete_operation.index, .length = delete_operation.length } },
            },
        };
    }
    var oracle = try fugue_oracle.HistoryOracle.init(allocator, events, order);
    defer oracle.deinit();
    return oracle.render(allocator);
}

fn deliverPermutation(
    changes: []const Change,
    seed: u64,
    expected: []const u8,
    allocator: std.mem.Allocator,
) !void {
    var permutation = try allocator.alloc(usize, changes.len);
    defer allocator.free(permutation);
    for (permutation, 0..) |*index, i| index.* = i;
    var rng = Lcg.init(seed);
    var i = permutation.len;
    while (i > 1) {
        i -= 1;
        const swap_index = @as(usize, @intCast(rng.next() % (i + 1)));
        std.mem.swap(usize, &permutation[i], &permutation[swap_index]);
    }

    var target = try Replica.init(allocator, actor(250));
    defer target.deinit();
    for (permutation) |change_index| _ = try target.receive(&changes[change_index]);
    for (permutation) |change_index| _ = try target.receive(&changes[change_index]);
    try std.testing.expectEqual(@as(usize, 0), target.pendingCount());
    try std.testing.expectEqualStrings(expected, target.textView());
}

fn actorFromName(name: []const u8) !ActorId {
    if (name.len > 16) return error.ActorNameTooLong;
    var result = [_]u8{0} ** 16;
    @memcpy(result[0..name.len], name);
    return result;
}

fn jsonNonNegative(value: std.json.Value) !usize {
    return switch (value) {
        .integer => |number| if (number < 0) error.InvalidExternalTrace else @intCast(number),
        else => error.InvalidExternalTrace,
    };
}

fn externalPatch(value: std.json.Value) !struct { position: usize, deleted: usize, inserted: []const u8 } {
    const values = switch (value) {
        .array => |array| array.items,
        else => return error.InvalidExternalTrace,
    };
    if (values.len != 3) return error.InvalidExternalTrace;
    const inserted = switch (values[2]) {
        .string => |text| text,
        else => return error.InvalidExternalTrace,
    };
    return .{
        .position = try jsonNonNegative(values[0]),
        .deleted = try jsonNonNegative(values[1]),
        .inserted = inserted,
    };
}

fn receiveExternalOperation(
    replica: *Replica,
    allocator: std.mem.Allocator,
    operation_id: OpId,
    parents: []const OpId,
    operation: Operation,
) !void {
    var source_operation = operation;
    var operation_owned = true;
    errdefer if (operation_owned) source_operation.deinit(allocator);
    var change = try Change.init(allocator, operation_id, parents, source_operation);
    defer change.deinit(allocator);
    source_operation.deinit(allocator);
    operation_owned = false;
    switch (try replica.receive(&change)) {
        .applied => {},
        .duplicate, .pending => return error.InvalidExternalTrace,
    }
}

fn replayExternalTrace(trace: *const ExternalTrace, allocator: std.mem.Allocator) ![]u8 {
    // The corpus uses short agent names (a, b, c).  Zero-padding those names
    // preserves their lexicographic ordering in OpId.actor, which is the
    // ordering contract used by the Zig implementation.
    // The checked-in corpus is produced by the plain Fugue/YjsMod rule,
    // rather than the native FugueMax default.
    var replica = try Replica.initWithOrdering(allocator, actor(0xff), .fugue);
    defer replica.deinit();

    var local_versions: std.ArrayList(OpId) = .empty;
    defer local_versions.deinit(allocator);

    for (trace.txns) |transaction| {
        if (transaction.span[0] != local_versions.items.len) return error.InvalidExternalTrace;
        if (transaction.span[1] < transaction.span[0]) return error.InvalidExternalTrace;

        var transaction_parents: std.ArrayList(OpId) = .empty;
        defer transaction_parents.deinit(allocator);
        for (transaction.parents) |parent_version| {
            if (parent_version >= local_versions.items.len) return error.InvalidExternalTrace;
            try transaction_parents.append(allocator, local_versions.items[parent_version]);
        }

        const transaction_actor = try actorFromName(transaction.agent);
        var operation_offset: usize = 0;
        var previous_id: ?OpId = null;

        for (transaction.ops) |raw_patch| {
            const patch = try externalPatch(raw_patch);
            if (patch.deleted != 0 and patch.inserted.len != 0) return error.InvalidExternalTrace;

            if (patch.deleted != 0) {
                var deleted: usize = 0;
                while (deleted < patch.deleted) : (deleted += 1) {
                    if (operation_offset >= transaction.span[1] - transaction.span[0]) return error.InvalidExternalTrace;
                    const current_id = OpId{
                        .actor = transaction_actor,
                        .counter = @intCast(transaction.seqStart + operation_offset),
                    };
                    var parent_buffer: [1]OpId = undefined;
                    const parents = if (previous_id) |parent| blk: {
                        parent_buffer[0] = parent;
                        break :blk parent_buffer[0..1];
                    } else transaction_parents.items;
                    try receiveExternalOperation(
                        replica,
                        allocator,
                        current_id,
                        parents,
                        Operation.initDelete(patch.position, 1),
                    );
                    try local_versions.append(allocator, current_id);
                    previous_id = current_id;
                    operation_offset += 1;
                }
            } else {
                const view = std.unicode.Utf8View.init(patch.inserted) catch return error.InvalidExternalTrace;
                var iterator = view.iterator();
                var inserted_offset: usize = 0;
                while (iterator.nextCodepointSlice()) |scalar| {
                    if (operation_offset >= transaction.span[1] - transaction.span[0]) return error.InvalidExternalTrace;
                    const current_id = OpId{
                        .actor = transaction_actor,
                        .counter = @intCast(transaction.seqStart + operation_offset),
                    };
                    var parent_buffer: [1]OpId = undefined;
                    const parents = if (previous_id) |parent| blk: {
                        parent_buffer[0] = parent;
                        break :blk parent_buffer[0..1];
                    } else transaction_parents.items;
                    try receiveExternalOperation(
                        replica,
                        allocator,
                        current_id,
                        parents,
                        try Operation.initInsert(allocator, patch.position + inserted_offset, scalar),
                    );
                    try local_versions.append(allocator, current_id);
                    previous_id = current_id;
                    operation_offset += 1;
                    inserted_offset += 1;
                }
            }
        }

        if (operation_offset != transaction.span[1] - transaction.span[0]) return error.InvalidExternalTrace;
    }

    return replica.text(allocator);
}

test "generated causal DAGs agree with independent Eg-walker replay" {
    var changes = try collectGeneratedChanges(std.testing.allocator);
    defer {
        for (changes.items) |change| change.deinit(std.testing.allocator);
        changes.deinit(std.testing.allocator);
    }
    try std.testing.expect(changes.items.len >= 80);

    const expected = try expectedForChanges(changes.items, std.testing.allocator);
    defer std.testing.allocator.free(expected);

    const seeds = [_]u64{
        0x01,
        0x02,
        0x11,
        0x29,
        0x7f,
        0xdead_beef,
        0xfeed_face,
        0x1234_5678,
    };
    for (seeds) |seed| try deliverPermutation(changes.items, seed, expected, std.testing.allocator);
}

test "generated DAG contains offline branches and a merge frontier" {
    var changes = try collectGeneratedChanges(std.testing.allocator);
    defer {
        for (changes.items) |change| change.deinit(std.testing.allocator);
        changes.deinit(std.testing.allocator);
    }

    var actors_seen: std.AutoHashMap(ActorId, void) = std.AutoHashMap(ActorId, void).init(std.testing.allocator);
    defer actors_seen.deinit();
    var has_branch_parent = false;
    for (changes.items) |change| {
        try actors_seen.put(change.id.actor, {});
        if (change.parents.items.len > 1) has_branch_parent = true;
    }
    try std.testing.expect(actors_seen.count() >= 4);
    try std.testing.expect(has_branch_parent);
}

test "selected traces from the checked-in Eg-walker corpus match their reference text" {
    if (!external_data.available) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const traces = try std.json.parseFromSliceLeaky(
        []ExternalTrace,
        arena.allocator(),
        external_data.json,
        .{},
    );
    try std.testing.expect(traces.len >= 1000);

    if (external_data.trace_index != std.math.maxInt(usize)) {
        if (external_data.trace_index >= traces.len) return error.InvalidExternalTrace;
        const trace = &traces[external_data.trace_index];
        const actual = try replayExternalTrace(trace, std.testing.allocator);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(trace.endContent, actual);
    } else if (external_data.full) {
        for (traces) |*trace| {
            const actual = try replayExternalTrace(trace, std.testing.allocator);
            defer std.testing.allocator.free(actual);
            try std.testing.expectEqualStrings(trace.endContent, actual);
        }
    } else {
        // Keep the default test invocation quick while spreading these cases
        // over the checked-in corpus. `zig build reference-test -Dfull-external`
        // runs all 1000 traces.
        const selected = [_]usize{ 0, 1, 2, 7, 31, 127, 255, 511, 767, 999 };
        for (selected) |trace_index| {
            const actual = try replayExternalTrace(&traces[trace_index], std.testing.allocator);
            defer std.testing.allocator.free(actual);
            try std.testing.expectEqualStrings(traces[trace_index].endContent, actual);
        }
    }
}
