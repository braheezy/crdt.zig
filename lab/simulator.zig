//! Deterministic, in-process distributed-systems lab for the CRDT library.
//!
//! This module deliberately models transport outside the CRDT core. A World
//! owns independent replicas and an unreliable queue of owned Change values.
//! Tests and examples can introduce partitions, delay, reordering, drops,
//! duplicates, and restarts, then make the network reliable and require every
//! replica to converge.

const std = @import("std");
const collab = @import("collab");

pub const ActorId = collab.ActorId;
pub const Change = collab.Change;
pub const OpId = collab.OpId;
pub const Ordering = collab.Ordering;
pub const Replica = collab.Replica;
pub const ReceiveResult = collab.ReceiveResult;

pub const LabError = error{
    InvalidNode,
    InvalidConfiguration,
    InvalidBatchLimit,
    ReplicaInvariantViolation,
    OperationContractViolation,
    ReceiveContractViolation,
    RestartMismatch,
    DeliveryLimit,
    DidNotConverge,
};

pub const Faults = struct {
    /// Probability that a newly-sent change is discarded by the transport.
    drop_percent: u8 = 0,
    /// Probability that a successfully queued change is queued a second time.
    duplicate_percent: u8 = 0,
    /// Maximum simulated delivery delay, in logical ticks.
    max_delay: u32 = 0,
    /// When true, the scheduler may choose any deliverable envelope rather
    /// than the oldest envelope.
    reorder: bool = true,

    pub fn validate(self: Faults) !void {
        if (self.drop_percent > 100 or self.duplicate_percent > 100) {
            return LabError.InvalidConfiguration;
        }
    }
};

pub const NetworkStats = struct {
    sync_attempts: usize = 0,
    blocked_syncs: usize = 0,
    sent_changes: usize = 0,
    queued_envelopes: usize = 0,
    delivered_envelopes: usize = 0,
    dropped_changes: usize = 0,
    injected_duplicates: usize = 0,
    applied_receives: usize = 0,
    pending_receives: usize = 0,
    duplicate_receives: usize = 0,
    restarts: usize = 0,
    invariant_checks: usize = 0,
};

const Prng = struct {
    state: u64,

    fn init(seed: u64) Prng {
        return .{ .state = if (seed == 0) 0x9e3779b97f4a7c15 else seed };
    }

    fn next(self: *Prng) u64 {
        var value = self.state;
        value ^= value << 13;
        value ^= value >> 7;
        value ^= value << 17;
        self.state = if (value == 0) 0x9e3779b97f4a7c15 else value;
        return self.state;
    }

    fn below(self: *Prng, upper: usize) usize {
        std.debug.assert(upper != 0);
        return @intCast(self.next() % upper);
    }
};

const Envelope = struct {
    id: u64,
    from: usize,
    to: usize,
    ready_at: u64,
    duplicate_of: ?u64,
    change: Change,

    fn deinit(self: Envelope, allocator: std.mem.Allocator) void {
        self.change.deinit(allocator);
    }
};

pub const World = struct {
    allocator: std.mem.Allocator,
    replicas: []*Replica,
    links: []bool,
    queue: std.ArrayList(Envelope) = .empty,
    trace: std.ArrayList(u8) = .empty,
    capture_trace: bool,
    faults: Faults,
    rng: Prng,
    tick: u64 = 0,
    next_message_id: u64 = 0,
    network_stats: NetworkStats = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        replica_count: usize,
        seed: u64,
        ordering: Ordering,
        faults: Faults,
        capture_trace: bool,
    ) !World {
        if (replica_count == 0) return LabError.InvalidConfiguration;
        try faults.validate();

        const replicas = try allocator.alloc(*Replica, replica_count);
        errdefer allocator.free(replicas);
        var initialized: usize = 0;
        errdefer for (replicas[0..initialized]) |node_replica| node_replica.deinit();

        for (replicas, 0..) |*slot, i| {
            slot.* = try Replica.initWithOrdering(allocator, actorForNode(i), ordering);
            initialized += 1;
        }

        const link_count = std.math.mul(usize, replica_count, replica_count) catch {
            return LabError.InvalidConfiguration;
        };
        const links = try allocator.alloc(bool, link_count);
        errdefer allocator.free(links);
        @memset(links, true);
        for (0..replica_count) |i| links[i * replica_count + i] = false;

        return .{
            .allocator = allocator,
            .replicas = replicas,
            .links = links,
            .capture_trace = capture_trace,
            .faults = faults,
            .rng = Prng.init(seed),
        };
    }

    pub fn deinit(self: *World) void {
        for (self.queue.items) |envelope| envelope.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        self.trace.deinit(self.allocator);
        for (self.replicas) |node_replica| node_replica.deinit();
        self.allocator.free(self.replicas);
        self.allocator.free(self.links);
    }

    pub fn replicaCount(self: *const World) usize {
        return self.replicas.len;
    }

    pub fn replica(self: *World, node: usize) !*Replica {
        try self.validateNode(node);
        return self.replicas[node];
    }

    pub fn traceView(self: *const World) []const u8 {
        return self.trace.items;
    }

    pub fn queuedCount(self: *const World) usize {
        return self.queue.items.len;
    }

    pub fn stats(self: *const World) NetworkStats {
        return self.network_stats;
    }

    pub fn insert(self: *World, node: usize, index: usize, text: []const u8) !OpId {
        try self.validateNode(node);
        const before = self.replicas[node].stats();
        const inserted_scalars = std.unicode.utf8CountCodepoints(text) catch {
            return LabError.OperationContractViolation;
        };
        const change_id = try self.replicas[node].insert(index, text);
        try self.record(
            "tick={} insert node={} index={} text={s} actor_tail={} counter={}",
            .{ self.tick, node, index, text, change_id.actor[15], change_id.counter },
        );
        const after = self.replicas[node].stats();
        if (after.history_events != before.history_events + 1 or
            after.pending_events != before.pending_events or
            after.text_scalars != before.text_scalars + inserted_scalars or
            !self.replicas[node].hasChange(change_id))
        {
            return LabError.OperationContractViolation;
        }
        try self.assertReplicaInvariant(node);
        return change_id;
    }

    pub fn delete(self: *World, node: usize, index: usize, length: usize) !OpId {
        try self.validateNode(node);
        const before = self.replicas[node].stats();
        const change_id = try self.replicas[node].delete(index, length);
        try self.record(
            "tick={} delete node={} index={} length={} actor_tail={} counter={}",
            .{ self.tick, node, index, length, change_id.actor[15], change_id.counter },
        );
        const after = self.replicas[node].stats();
        if (after.history_events != before.history_events + 1 or
            after.pending_events != before.pending_events or
            before.text_scalars < length or
            after.text_scalars != before.text_scalars - length or
            !self.replicas[node].hasChange(change_id))
        {
            return LabError.OperationContractViolation;
        }
        try self.assertReplicaInvariant(node);
        return change_id;
    }

    pub fn setLink(self: *World, from: usize, to: usize, up: bool) !void {
        try self.validateDistinctNodes(from, to);
        self.links[self.linkIndex(from, to)] = up;
        try self.record("tick={} link from={} to={} state={s}", .{
            self.tick,
            from,
            to,
            if (up) "up" else "down",
        });
    }

    pub fn partition(self: *World, first: usize, second: usize) !void {
        try self.validateDistinctNodes(first, second);
        self.links[self.linkIndex(first, second)] = false;
        self.links[self.linkIndex(second, first)] = false;
        try self.record("tick={} partition first={} second={}", .{ self.tick, first, second });
    }

    pub fn heal(self: *World, first: usize, second: usize) !void {
        try self.validateDistinctNodes(first, second);
        self.links[self.linkIndex(first, second)] = true;
        self.links[self.linkIndex(second, first)] = true;
        try self.record("tick={} heal first={} second={}", .{ self.tick, first, second });
    }

    pub fn healAll(self: *World) !void {
        for (0..self.replicas.len) |from| {
            for (0..self.replicas.len) |to| {
                self.links[self.linkIndex(from, to)] = from != to;
            }
        }
        try self.record("tick={} heal-all", .{self.tick});
    }

    pub fn linkIsUp(self: *const World, from: usize, to: usize) !bool {
        try self.validateDistinctNodes(from, to);
        return self.links[self.linkIndex(from, to)];
    }

    /// Queue at most `max_changes` changes that `to` does not currently
    /// advertise. The transport owns clones of the queued changes. A later
    /// sync retries anything dropped by the fault model.
    pub fn sync(self: *World, from: usize, to: usize, max_changes: usize) !usize {
        try self.validateDistinctNodes(from, to);
        if (max_changes == 0) return LabError.InvalidBatchLimit;
        self.network_stats.sync_attempts += 1;

        if (!self.links[self.linkIndex(from, to)]) {
            self.network_stats.blocked_syncs += 1;
            try self.record("tick={} sync-blocked from={} to={}", .{ self.tick, from, to });
            return 0;
        }

        var have = try self.replicas[to].have(self.allocator);
        defer have.deinit();
        var changes = try self.replicas[from].changesForHave(&have, self.allocator);
        defer {
            for (changes.items) |change| change.deinit(self.allocator);
            changes.deinit(self.allocator);
        }

        const count = @min(max_changes, changes.items.len);
        for (changes.items[0..count]) |*change| try self.sendChange(from, to, change);
        try self.record("tick={} sync from={} to={} offered={}", .{ self.tick, from, to, count });
        return count;
    }

    /// Reverse the queue explicitly. This is useful for a guaranteed
    /// child-before-parent delivery fixture rather than relying on chance.
    pub fn reverseQueue(self: *World) !void {
        std.mem.reverse(Envelope, self.queue.items);
        try self.record("tick={} reverse-queue count={}", .{ self.tick, self.queue.items.len });
    }

    /// Deliver one envelope if at least one queued route is connected.
    /// Returns false when the queue is empty or every queued route is blocked.
    pub fn deliverOne(self: *World) !bool {
        if (self.queue.items.len == 0) return false;

        var candidate_index: ?usize = null;
        if (self.faults.reorder) {
            var available: usize = 0;
            for (self.queue.items) |envelope| {
                if (self.links[self.linkIndex(envelope.from, envelope.to)]) available += 1;
            }
            if (available == 0) return false;
            var wanted = self.rng.below(available);
            for (self.queue.items, 0..) |envelope, i| {
                if (!self.links[self.linkIndex(envelope.from, envelope.to)]) continue;
                if (wanted == 0) {
                    candidate_index = i;
                    break;
                }
                wanted -= 1;
            }
        } else {
            var earliest: u64 = std.math.maxInt(u64);
            for (self.queue.items, 0..) |envelope, i| {
                if (!self.links[self.linkIndex(envelope.from, envelope.to)]) continue;
                if (candidate_index == null or envelope.ready_at < earliest) {
                    candidate_index = i;
                    earliest = envelope.ready_at;
                }
            }
        }

        const index = candidate_index orelse return false;
        var envelope = self.queue.orderedRemove(index);
        defer envelope.deinit(self.allocator);
        self.tick = @max(self.tick, envelope.ready_at);

        const before = self.replicas[envelope.to].stats();
        const before_text_checksum = std.hash.Wyhash.hash(0, self.replicas[envelope.to].textView());
        const result = try self.replicas[envelope.to].receive(&envelope.change);
        const after = self.replicas[envelope.to].stats();
        self.network_stats.delivered_envelopes += 1;
        switch (result) {
            .applied => {
                self.network_stats.applied_receives += 1;
                if (after.history_events <= before.history_events) {
                    return LabError.ReceiveContractViolation;
                }
            },
            .pending => {
                self.network_stats.pending_receives += 1;
                if (after.history_events != before.history_events or
                    after.pending_events < before.pending_events or
                    after.pending_events > before.pending_events + 1 or
                    std.hash.Wyhash.hash(0, self.replicas[envelope.to].textView()) != before_text_checksum)
                {
                    return LabError.ReceiveContractViolation;
                }
            },
            .duplicate => {
                self.network_stats.duplicate_receives += 1;
                if (after.history_events != before.history_events or
                    after.pending_events != before.pending_events or
                    std.hash.Wyhash.hash(0, self.replicas[envelope.to].textView()) != before_text_checksum)
                {
                    return LabError.ReceiveContractViolation;
                }
            },
        }
        try self.record(
            "tick={} deliver message={} from={} to={} duplicate_of={any} result={s}",
            .{ self.tick, envelope.id, envelope.from, envelope.to, envelope.duplicate_of, @tagName(result) },
        );
        self.tick +%= 1;
        try self.assertReplicaInvariant(envelope.to);
        return true;
    }

    /// Drain connected messages with an explicit safety bound.
    pub fn deliverAll(self: *World, max_deliveries: usize) !usize {
        var delivered: usize = 0;
        while (delivered < max_deliveries and try self.deliverOne()) delivered += 1;
        if (delivered == max_deliveries and self.hasDeliverable()) return LabError.DeliveryLimit;
        return delivered;
    }

    /// Replace a node with a save/load round trip while retaining messages
    /// already in flight to or from that node.
    pub fn restart(self: *World, node: usize) !void {
        try self.validateNode(node);
        const before = self.replicas[node].stats();
        const bytes = try self.replicas[node].save(self.allocator);
        defer self.allocator.free(bytes);
        const loaded = try Replica.load(self.allocator, bytes);
        var loaded_owned = true;
        errdefer if (loaded_owned) loaded.deinit();
        const after = loaded.stats();
        if (!std.mem.eql(u8, self.replicas[node].textView(), loaded.textView()) or
            !std.mem.eql(u8, &before.actor, &after.actor) or
            before.ordering != after.ordering or
            before.next_counter != after.next_counter or
            before.history_events != after.history_events or
            before.pending_events != after.pending_events or
            before.frontier_heads != after.frontier_heads or
            before.text_bytes != after.text_bytes or
            before.text_scalars != after.text_scalars or
            !opIdSlicesEqual(self.replicas[node].frontierView(), loaded.frontierView()))
        {
            return LabError.RestartMismatch;
        }
        self.replicas[node].deinit();
        self.replicas[node] = loaded;
        loaded_owned = false;
        self.network_stats.restarts += 1;
        try self.record("tick={} restart node={}", .{ self.tick, node });
    }

    /// Make every route reliable and run repeated all-to-all anti-entropy
    /// rounds. Fault settings are restored afterward so callers may continue
    /// experimenting with the same world.
    pub fn settleReliably(self: *World, max_rounds: usize, batch_limit: usize) !usize {
        if (max_rounds == 0 or batch_limit == 0) return LabError.InvalidConfiguration;
        const saved_faults = self.faults;
        defer self.faults = saved_faults;
        self.faults.drop_percent = 0;
        self.faults.duplicate_percent = 0;
        self.faults.max_delay = 0;
        try self.healAll();

        for (0..max_rounds) |round| {
            for (0..self.replicas.len) |from| {
                for (0..self.replicas.len) |to| {
                    if (from == to) continue;
                    _ = try self.sync(from, to, batch_limit);
                }
            }
            _ = try self.deliverAll(1 << 22);
            if (self.queue.items.len == 0 and try self.isConverged()) {
                try self.record("tick={} converged round={}", .{ self.tick, round + 1 });
                return round + 1;
            }
        }
        return LabError.DidNotConverge;
    }

    /// Convergence means equal rendered text, no unresolved pending changes,
    /// and equal accepted-ID sets. Equal text alone is not sufficient because
    /// two replicas can temporarily render the same bytes with different
    /// causal histories.
    pub fn isConverged(self: *World) !bool {
        if (self.replicas.len == 0) return true;
        const expected_text = self.replicas[0].textView();
        const expected_frontier = self.replicas[0].frontierView();
        const expected_ordering = self.replicas[0].orderingMode();
        var expected_have = try self.replicas[0].have(self.allocator);
        defer expected_have.deinit();

        for (self.replicas) |candidate| {
            if (candidate.pendingCount() != 0) return false;
            if (!std.mem.eql(u8, expected_text, candidate.textView())) return false;
            if (candidate.orderingMode() != expected_ordering) return false;
            if (!opIdSlicesEqual(expected_frontier, candidate.frontierView())) return false;
            var candidate_have = try candidate.have(self.allocator);
            defer candidate_have.deinit();
            if (!expected_have.isSubsetOf(&candidate_have) or !candidate_have.isSubsetOf(&expected_have)) {
                return false;
            }
        }
        return true;
    }

    pub fn assertConverged(self: *World) !void {
        if (!try self.isConverged()) return LabError.DidNotConverge;
    }

    /// Check inexpensive public invariants after generated mutations. This is
    /// intentionally independent of the library's internal representation.
    pub fn assertReplicaInvariants(self: *World) !void {
        for (0..self.replicas.len) |node| try self.assertReplicaInvariant(node);
    }

    fn assertReplicaInvariant(self: *World, node: usize) !void {
        const candidate = self.replicas[node];
        const text = candidate.textView();
        if (!std.unicode.utf8ValidateSlice(text)) return LabError.ReplicaInvariantViolation;
        const scalar_count = std.unicode.utf8CountCodepoints(text) catch {
            return LabError.ReplicaInvariantViolation;
        };
        const candidate_stats = candidate.stats();
        const candidate_actor = candidate.actorId();
        if (!std.mem.eql(u8, &candidate_stats.actor, &candidate_actor) or
            candidate_stats.ordering != candidate.orderingMode() or
            candidate_stats.history_events != candidate.historyCount() or
            candidate_stats.pending_events != candidate.pendingCount() or
            candidate_stats.frontier_heads != candidate.frontierView().len or
            candidate_stats.text_bytes != text.len or
            candidate_stats.text_scalars != scalar_count or
            candidate_stats.text_scalars != candidate.visibleScalarCount())
        {
            return LabError.ReplicaInvariantViolation;
        }

        const frontier = candidate.frontierView();
        for (frontier, 0..) |head, i| {
            if (!candidate.hasChange(head)) return LabError.ReplicaInvariantViolation;
            if (i != 0 and frontier[i - 1].order(head) != .lt) {
                return LabError.ReplicaInvariantViolation;
            }
        }
        self.network_stats.invariant_checks += 1;
    }

    fn sendChange(self: *World, from: usize, to: usize, change: *const Change) !void {
        self.network_stats.sent_changes += 1;
        if (self.chance(self.faults.drop_percent)) {
            self.network_stats.dropped_changes += 1;
            try self.record(
                "tick={} drop from={} to={} actor_tail={} counter={}",
                .{ self.tick, from, to, change.id.actor[15], change.id.counter },
            );
            return;
        }

        const original_id = self.next_message_id;
        try self.enqueueClone(from, to, change, null);
        if (self.chance(self.faults.duplicate_percent)) {
            try self.enqueueClone(from, to, change, original_id);
            self.network_stats.injected_duplicates += 1;
        }
    }

    fn enqueueClone(
        self: *World,
        from: usize,
        to: usize,
        change: *const Change,
        duplicate_of: ?u64,
    ) !void {
        var copy = try change.clone(self.allocator);
        var moved = false;
        errdefer if (!moved) copy.deinit(self.allocator);

        const message_id = self.next_message_id;
        self.next_message_id +%= 1;
        try self.queue.append(self.allocator, .{
            .id = message_id,
            .from = from,
            .to = to,
            .ready_at = self.tick +% self.randomDelay(),
            .duplicate_of = duplicate_of,
            .change = copy,
        });
        moved = true;
        self.network_stats.queued_envelopes += 1;
        try self.record(
            "tick={} queue message={} from={} to={} ready={} duplicate_of={any}",
            .{ self.tick, message_id, from, to, self.queue.items[self.queue.items.len - 1].ready_at, duplicate_of },
        );
    }

    fn chance(self: *World, percent: u8) bool {
        if (percent == 0) return false;
        if (percent == 100) return true;
        return self.rng.next() % 100 < percent;
    }

    fn randomDelay(self: *World) u64 {
        if (self.faults.max_delay == 0) return 0;
        return self.rng.next() % (@as(u64, self.faults.max_delay) + 1);
    }

    fn hasDeliverable(self: *const World) bool {
        for (self.queue.items) |envelope| {
            if (self.links[self.linkIndex(envelope.from, envelope.to)]) return true;
        }
        return false;
    }

    fn validateNode(self: *const World, node: usize) !void {
        if (node >= self.replicas.len) return LabError.InvalidNode;
    }

    fn validateDistinctNodes(self: *const World, first: usize, second: usize) !void {
        try self.validateNode(first);
        try self.validateNode(second);
        if (first == second) return LabError.InvalidNode;
    }

    fn linkIndex(self: *const World, from: usize, to: usize) usize {
        return from * self.replicas.len + to;
    }

    fn record(self: *World, comptime format: []const u8, args: anytype) !void {
        if (!self.capture_trace) return;
        try self.trace.print(self.allocator, format ++ "\n", args);
    }
};

fn opIdSlicesEqual(first: []const OpId, second: []const OpId) bool {
    if (first.len != second.len) return false;
    for (first, second) |a, b| {
        if (!a.eql(b)) return false;
    }
    return true;
}

pub const Scenario = enum {
    offline,
    partition,
    reorder,
    restart,
    random,

    pub fn name(self: Scenario) []const u8 {
        return @tagName(self);
    }

    pub fn parse(value: []const u8) !Scenario {
        inline for (std.meta.fields(Scenario)) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return LabError.InvalidConfiguration;
    }
};

pub const ScenarioOptions = struct {
    seed: u64 = 0xc0ffee,
    replicas: usize = 3,
    actions: usize = 48,
    batch_limit: usize = 16,
    settle_rounds: usize = 128,
    ordering: Ordering = .fugue_max,
    faults: Faults = .{
        .drop_percent = 10,
        .duplicate_percent = 15,
        .max_delay = 8,
        .reorder = true,
    },
    capture_trace: bool = false,
};

pub const Report = struct {
    allocator: std.mem.Allocator,
    scenario: Scenario,
    seed: u64,
    replicas: usize,
    actions: usize,
    settle_rounds: usize,
    network: NetworkStats,
    history_events: usize,
    text_scalars: usize,
    checksum: u64,
    final_text: []u8,
    trace: []u8,

    pub fn deinit(self: *Report) void {
        self.allocator.free(self.final_text);
        self.allocator.free(self.trace);
    }
};

pub fn runScenario(
    allocator: std.mem.Allocator,
    scenario: Scenario,
    options: ScenarioOptions,
) !Report {
    return runScenarioInternal(allocator, scenario, options, null);
}

/// Run a scenario and preserve its logical trace when the scenario fails.
/// The output list uses `allocator`, is cleared before the run, and remains
/// empty on success. Trace capture is forced internally only for this call.
pub fn runScenarioCapturingFailure(
    allocator: std.mem.Allocator,
    scenario: Scenario,
    options: ScenarioOptions,
    failure_trace: *std.ArrayList(u8),
) !Report {
    failure_trace.clearRetainingCapacity();
    return runScenarioInternal(allocator, scenario, options, failure_trace);
}

fn runScenarioInternal(
    allocator: std.mem.Allocator,
    scenario: Scenario,
    options: ScenarioOptions,
    failure_trace: ?*std.ArrayList(u8),
) !Report {
    if (options.replicas < 2 or options.batch_limit == 0 or options.settle_rounds == 0) {
        return LabError.InvalidConfiguration;
    }
    try options.faults.validate();

    const replica_count = switch (scenario) {
        .offline, .reorder, .restart => 2,
        .partition => @max(options.replicas, 3),
        .random => options.replicas,
    };
    var world = try World.init(
        allocator,
        replica_count,
        options.seed,
        options.ordering,
        options.faults,
        options.capture_trace or failure_trace != null,
    );
    defer world.deinit();
    errdefer if (failure_trace) |output| {
        output.appendSlice(allocator, world.traceView()) catch {};
    };

    const action_count = switch (scenario) {
        .offline => try scenarioOffline(&world),
        .partition => try scenarioPartition(&world, options),
        .reorder => try scenarioReorder(&world, options),
        .restart => try scenarioRestart(&world, options),
        .random => try scenarioRandom(&world, options),
    };
    try world.assertReplicaInvariants();
    const rounds = try world.settleReliably(options.settle_rounds, options.batch_limit);
    try world.assertReplicaInvariants();
    try world.assertConverged();

    const replica_stats = world.replicas[0].stats();
    const final_text = try allocator.dupe(u8, world.replicas[0].textView());
    errdefer allocator.free(final_text);
    const trace = try allocator.dupe(u8, world.traceView());
    errdefer allocator.free(trace);
    return .{
        .allocator = allocator,
        .scenario = scenario,
        .seed = options.seed,
        .replicas = replica_count,
        .actions = action_count,
        .settle_rounds = rounds,
        .network = world.stats(),
        .history_events = replica_stats.history_events,
        .text_scalars = replica_stats.text_scalars,
        .checksum = std.hash.Wyhash.hash(0, final_text),
        .final_text = final_text,
        .trace = trace,
    };
}

fn scenarioOffline(world: *World) !usize {
    _ = try world.insert(0, 0, "alpha");
    _ = try world.insert(0, world.replicas[0].visibleScalarCount(), "-A");
    _ = try world.insert(1, 0, "beta");
    _ = try world.insert(1, world.replicas[1].visibleScalarCount(), "-B");
    return 4;
}

fn scenarioPartition(world: *World, options: ScenarioOptions) !usize {
    _ = try world.insert(0, 0, "base");
    _ = try world.settleReliably(options.settle_rounds, options.batch_limit);

    for (1..world.replicas.len) |peer| try world.partition(0, peer);
    _ = try world.insert(0, world.replicas[0].visibleScalarCount(), "-isolated");
    _ = try world.insert(1, 0, "peer-");
    if (world.replicas.len > 2) {
        _ = try world.insert(2, world.replicas[2].visibleScalarCount(), "-third");
        _ = try world.sync(1, 2, options.batch_limit);
        _ = try world.deliverAll(1 << 16);
    }
    _ = try world.sync(0, 1, options.batch_limit);
    _ = try world.sync(1, 0, options.batch_limit);
    return if (world.replicas.len > 2) 7 else 5;
}

fn scenarioReorder(world: *World, options: ScenarioOptions) !usize {
    _ = try world.insert(0, 0, "a");
    _ = try world.insert(0, 1, "b");
    _ = try world.insert(0, 2, "c");
    _ = try world.sync(0, 1, options.batch_limit);
    try world.reverseQueue();
    const saved_reorder = world.faults.reorder;
    world.faults.reorder = false;
    defer world.faults.reorder = saved_reorder;
    _ = try world.deliverAll(1 << 16);
    return 5;
}

fn scenarioRestart(world: *World, options: ScenarioOptions) !usize {
    _ = try world.insert(0, 0, "before");
    _ = try world.settleReliably(options.settle_rounds, options.batch_limit);
    _ = try world.insert(1, world.replicas[1].visibleScalarCount(), "-peer");
    try world.restart(1);
    _ = try world.insert(0, 0, "after-");
    return 4;
}

fn scenarioRandom(world: *World, options: ScenarioOptions) !usize {
    const snippets = [_][]const u8{ "a", "β", "XY", "🙂", "中" };
    var actions: usize = 0;
    while (actions < options.actions) : (actions += 1) {
        const choice = world.rng.next() % 100;
        if (choice < 55) {
            const node = world.rng.below(world.replicas.len);
            const visible = world.replicas[node].visibleScalarCount();
            if (visible == 0 or world.rng.next() % 4 != 0) {
                const index = if (visible == 0) 0 else world.rng.below(visible + 1);
                const text = snippets[world.rng.below(snippets.len)];
                _ = try world.insert(node, index, text);
            } else {
                const index = world.rng.below(visible);
                const remaining = visible - index;
                const length = 1 + world.rng.below(@min(remaining, 3));
                _ = try world.delete(node, index, length);
            }
        } else if (choice < 72) {
            const pair = randomPair(world);
            _ = try world.sync(pair[0], pair[1], options.batch_limit);
        } else if (choice < 84) {
            _ = try world.deliverOne();
        } else if (choice < 94) {
            const pair = randomPair(world);
            const up = try world.linkIsUp(pair[0], pair[1]);
            try world.setLink(pair[0], pair[1], !up);
        } else {
            try world.restart(world.rng.below(world.replicas.len));
        }
    }
    return actions;
}

fn randomPair(world: *World) [2]usize {
    const from = world.rng.below(world.replicas.len);
    var to = world.rng.below(world.replicas.len - 1);
    if (to >= from) to += 1;
    return .{ from, to };
}

fn actorForNode(index: usize) ActorId {
    var actor = [_]u8{0} ** 16;
    std.mem.writeInt(u64, actor[8..16], @intCast(index + 1), .big);
    return actor;
}

test "offline branches converge after reliable anti-entropy" {
    var report = try runScenario(std.testing.allocator, .offline, .{
        .capture_trace = true,
        .faults = .{},
    });
    defer report.deinit();

    try std.testing.expect(report.history_events == 4);
    try std.testing.expect(report.final_text.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, report.trace, "converged") != null);
}

test "reversed causal delivery exercises pending admission and still converges" {
    var report = try runScenario(std.testing.allocator, .reorder, .{
        .capture_trace = true,
        .batch_limit = 16,
        .faults = .{ .reorder = false },
    });
    defer report.deinit();

    try std.testing.expect(report.network.pending_receives > 0);
    try std.testing.expectEqualStrings("abc", report.final_text);
}

test "a healed partition converges all replicas" {
    var report = try runScenario(std.testing.allocator, .partition, .{
        .replicas = 3,
        .capture_trace = true,
        .faults = .{},
    });
    defer report.deinit();

    try std.testing.expect(report.network.blocked_syncs >= 2);
    try std.testing.expectEqual(@as(usize, 3), report.replicas);
    try std.testing.expect(report.history_events >= 4);
}

test "dropped messages are repaired by a later reliable sync" {
    var world = try World.init(std.testing.allocator, 2, 17, .fugue_max, .{
        .drop_percent = 100,
    }, true);
    defer world.deinit();

    _ = try world.insert(0, 0, "hello");
    _ = try world.sync(0, 1, 16);
    try std.testing.expectEqual(@as(usize, 0), world.queuedCount());
    try std.testing.expectEqual(@as(usize, 1), world.stats().dropped_changes);

    _ = try world.settleReliably(16, 16);
    try world.assertConverged();
    try std.testing.expectEqualStrings("hello", world.replicas[1].textView());
}

test "transport duplicates are observed as idempotent receives" {
    var world = try World.init(std.testing.allocator, 2, 19, .fugue_max, .{
        .duplicate_percent = 100,
    }, true);
    defer world.deinit();

    _ = try world.insert(0, 0, "once");
    _ = try world.sync(0, 1, 16);
    try std.testing.expectEqual(@as(usize, 2), world.queuedCount());
    _ = try world.deliverAll(16);

    try std.testing.expectEqual(@as(usize, 1), world.stats().injected_duplicates);
    try std.testing.expectEqual(@as(usize, 1), world.stats().duplicate_receives);
    try std.testing.expectEqualStrings("once", world.replicas[1].textView());
}

test "queued messages wait behind a partition and deliver after healing" {
    var world = try World.init(std.testing.allocator, 2, 23, .fugue_max, .{}, true);
    defer world.deinit();

    _ = try world.insert(0, 0, "queued");
    _ = try world.sync(0, 1, 16);
    try world.partition(0, 1);
    try std.testing.expectEqual(@as(usize, 0), try world.deliverAll(16));
    try std.testing.expectEqual(@as(usize, 1), world.queuedCount());

    try world.heal(0, 1);
    try std.testing.expectEqual(@as(usize, 1), try world.deliverAll(16));
    try std.testing.expectEqualStrings("queued", world.replicas[1].textView());
}

test "snapshot restart remains convergent" {
    var report = try runScenario(std.testing.allocator, .restart, .{
        .faults = .{},
    });
    defer report.deinit();

    try std.testing.expectEqual(@as(usize, 1), report.network.restarts);
    try std.testing.expect(report.history_events >= 3);
}

test "random scenarios are exactly reproducible from their seed" {
    const options = ScenarioOptions{
        .seed = 0xdecafbad,
        .replicas = 3,
        .actions = 24,
        .batch_limit = 8,
        .capture_trace = true,
    };
    var first = try runScenario(std.testing.allocator, .random, options);
    defer first.deinit();
    var second = try runScenario(std.testing.allocator, .random, options);
    defer second.deinit();

    try std.testing.expectEqual(first.checksum, second.checksum);
    try std.testing.expectEqualStrings(first.final_text, second.final_text);
    try std.testing.expectEqualStrings(first.trace, second.trace);
}

test "a failed scenario preserves a replay trace" {
    var failure_trace: std.ArrayList(u8) = .empty;
    defer failure_trace.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.DidNotConverge,
        runScenarioCapturingFailure(std.testing.allocator, .offline, .{
            .batch_limit = 1,
            .settle_rounds = 1,
            .faults = .{},
        }, &failure_trace),
    );
    try std.testing.expect(std.mem.indexOf(u8, failure_trace.items, "insert node=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure_trace.items, "sync from=0 to=1") != null);
}

test "a compact deterministic seed sweep converges" {
    for (0..24) |seed| {
        var report = try runScenario(std.testing.allocator, .random, .{
            .seed = @intCast(seed + 1),
            .replicas = 3,
            .actions = 16,
            .batch_limit = 6,
            .settle_rounds = 64,
            .faults = .{
                .drop_percent = 20,
                .duplicate_percent = 25,
                .max_delay = 12,
            },
        });
        report.deinit();
    }
}
