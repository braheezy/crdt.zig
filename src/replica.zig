const std = @import("std");
const id = @import("id.zig");
const operation_module = @import("operation.zig");
const change_module = @import("change.zig");
const merge_module = @import("merge_index.zig");
const fugue_oracle = @import("fugue_oracle.zig");
const sync_module = @import("sync.zig");

pub const ActorId = id.ActorId;
pub const OpId = id.OpId;
pub const Operation = operation_module.Operation;
pub const Change = change_module.Change;
pub const Have = sync_module.Have;
pub const CounterRange = sync_module.CounterRange;
const MergeIndex = merge_module.MergeIndex;
pub const Ordering = merge_module.Ordering;
const ElementId = merge_module.ElementId;
const EncodedScalar = merge_module.Scalar;
const InsertedElement = merge_module.Insert;

pub const ReceiveResult = enum {
    applied,
    duplicate,
    pending,
};

pub const Version = struct {
    frontier: std.ArrayList(OpId) = .empty,

    pub fn deinit(self: *Version, allocator: std.mem.Allocator) void {
        self.frontier.deinit(allocator);
    }
};

pub const VersionDiff = struct {
    only_from: std.ArrayList(OpId) = .empty,
    only_to: std.ArrayList(OpId) = .empty,

    pub fn deinit(self: *VersionDiff, allocator: std.mem.Allocator) void {
        self.only_from.deinit(allocator);
        self.only_to.deinit(allocator);
    }
};

/// A zero-allocation snapshot of the observable replica state.  This is
/// intentionally made up of scalar counters and the durable identity only;
/// it does not expose the temporary merge index or any borrowed storage.
/// Applications and benchmark harnesses can use it for diagnostics without
/// changing the replica or taking ownership of anything.
pub const ReplicaStats = struct {
    actor: ActorId,
    ordering: Ordering,
    next_counter: u64,
    history_events: usize,
    pending_events: usize,
    frontier_heads: usize,
    text_bytes: usize,
    text_scalars: usize,
};

/// Resource bounds applied while decoding a persisted replica. The defaults
/// are deliberately finite: a byte slice received from a file or transport
/// must not be able to turn a single varint into an unbounded allocation.
/// Applications that have a larger, trusted store can opt into larger limits
/// with `loadWithOptions`.
pub const LoadOptions = struct {
    max_input_bytes: usize = 256 * 1024 * 1024,
    max_events: usize = 1 << 20,
    max_pending: usize = 1 << 20,
    /// Maximum number of complete frames accepted from one ChangeLog replay.
    /// A log has no count header, so this bound is checked before decoding
    /// each frame and prevents an untrusted stream from growing the temporary
    /// decoded batch without limit.
    max_log_frames: usize = 1 << 20,
    max_parents_per_change: usize = 1 << 16,
    max_frame_bytes: usize = 64 * 1024 * 1024,
    max_insert_bytes: usize = 64 * 1024 * 1024,
};

pub const TailPolicy = enum {
    /// Any incomplete final frame is an error and leaves the destination
    /// replica unchanged.
    reject,
    /// Stop before an incomplete final frame and commit all complete frames
    /// before it. A complete frame with a bad checksum is never recoverable.
    recover,
};

pub const ReplayOptions = struct {
    tail_policy: TailPolicy = .reject,
    limits: LoadOptions = .{},
};

pub const ReplayResult = struct {
    frames: usize = 0,
    applied: usize = 0,
    duplicates: usize = 0,
    /// Number of pending changes left in the destination after replay.
    pending: usize = 0,
    /// Offset immediately after the last complete frame. With recovery this
    /// is the safe prefix that a caller may retain or rewrite.
    consumed_bytes: usize = 0,
    recovered_tail: bool = false,
};

/// Append-only stream of length/checksum framed `Change` records. This is a
/// delta log, not a complete `Replica.save` image: it has no header and can be
/// appended to by successive calls. `replay` validates the whole safe prefix
/// before changing its destination, so strict failures are atomic.
pub const ChangeLog = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) ChangeLog {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ChangeLog) void {
        self.bytes.deinit(self.allocator);
    }

    /// Append one owned-by-the-caller change without taking ownership of it.
    pub fn append(self: *ChangeLog, change: *const Change) !void {
        var encoded: std.ArrayList(u8) = .empty;
        defer encoded.deinit(self.allocator);
        try encodeLogFrame(&encoded, self.allocator, change);
        try self.appendEncoded(encoded.items);
    }

    /// Append a batch atomically with respect to allocation failure: the
    /// destination log is changed only after every frame has been encoded.
    pub fn appendBatch(self: *ChangeLog, changes: []const Change) !void {
        var encoded: std.ArrayList(u8) = .empty;
        defer encoded.deinit(self.allocator);
        for (changes) |*change| try encodeLogFrame(&encoded, self.allocator, change);
        try self.appendEncoded(encoded.items);
    }

    /// Append all changes absent from `known` in the replica's deterministic
    /// causal order. The temporary owned batch is released before returning.
    pub fn appendSince(self: *ChangeLog, source: *const Replica, known: *const Version) !void {
        var changes = try source.changesSince(known, self.allocator);
        defer {
            for (changes.items) |change| change.deinit(self.allocator);
            changes.deinit(self.allocator);
        }
        try self.appendBatch(changes.items);
    }

    /// Borrow the encoded stream. It remains valid until the next mutating
    /// call on this log or `deinit`.
    pub fn bytesView(self: *const ChangeLog) []const u8 {
        return self.bytes.items;
    }

    /// Transfer the encoded stream to the caller and leave the log empty.
    pub fn toOwnedSlice(self: *ChangeLog) ![]u8 {
        return self.bytes.toOwnedSlice(self.allocator);
    }

    pub fn replay(self: *const ChangeLog, replica: *Replica, options: ReplayOptions) !ReplayResult {
        return replica.replayLog(self.bytes.items, options);
    }

    fn appendEncoded(self: *ChangeLog, encoded: []const u8) !void {
        const size = @addWithOverflow(self.bytes.items.len, encoded.len);
        if (size[1] != 0) return error.LogTooLarge;
        try self.bytes.ensureTotalCapacity(self.allocator, size[0]);
        self.bytes.appendSliceAssumeCapacity(encoded);
    }
};

/// Owned changes returned by one incremental synchronization step.
pub const ChangeBatch = struct {
    changes: std.ArrayList(Change) = .empty,

    pub fn deinit(self: *ChangeBatch, allocator: std.mem.Allocator) void {
        for (self.changes.items) |change| change.deinit(allocator);
        self.changes.deinit(allocator);
    }

    pub fn len(self: *const ChangeBatch) usize {
        return self.changes.items.len;
    }

    pub fn isEmpty(self: *const ChangeBatch) bool {
        return self.changes.items.len == 0;
    }
};

/// One user-visible edit used by `Replica.applyGroup`.  The input text is
/// borrowed for the duration of that call; the resulting `ChangeBatch` owns
/// independent copies of every generated change.
pub const Edit = union(enum) {
    insert: struct {
        index: usize,
        text: []const u8,
    },
    delete: struct {
        index: usize,
        length: usize,
    },
};

/// Sender-side anti-entropy progress. The cursor owns a copy of the peer's
/// accepted-ID summary. `next` does not advance it: callers acknowledge a
/// batch only after the peer has accepted it, so a lost or rejected batch is
/// returned again on the next call.
pub const SyncCursor = struct {
    known: Have,

    pub fn init(allocator: std.mem.Allocator, known: *const Have) !SyncCursor {
        return .{ .known = try known.clone(allocator) };
    }

    pub fn deinit(self: *SyncCursor) void {
        self.known.deinit();
    }

    pub fn knownView(self: *const SyncCursor) []const CounterRange {
        return self.known.rangesView();
    }

    /// Return at most `max_changes` dependency-ordered changes that are not
    /// represented by the peer summary. A zero limit is rejected so callers
    /// cannot accidentally create a progress loop.
    pub fn next(
        self: *const SyncCursor,
        source: *const Replica,
        max_changes: usize,
        allocator: std.mem.Allocator,
    ) !ChangeBatch {
        if (max_changes == 0) return error.InvalidBatchLimit;

        const order = try source.topologicalOrder(allocator);
        defer allocator.free(order);

        var result = ChangeBatch{};
        errdefer result.deinit(allocator);
        for (order) |event_index| {
            const event = &source.events.items[event_index];
            if (self.known.contains(event.change.id)) continue;
            var cloned = try event.change.clone(allocator);
            var moved = false;
            errdefer if (!moved) cloned.deinit(allocator);
            try result.changes.append(allocator, cloned);
            moved = true;
            if (result.changes.items.len == max_changes) break;
        }
        return result;
    }

    /// Advance sender progress after the receiver has acknowledged the batch.
    /// The batch remains owned by its caller and may be deinitialized after
    /// this method returns.
    pub fn acknowledge(self: *SyncCursor, batch: *const ChangeBatch) !void {
        const required = @addWithOverflow(self.known.ranges.items.len, batch.changes.items.len);
        if (required[1] != 0) return error.TooManyRanges;
        // Each change can add at most one raw range.  Reserve before the
        // first logical update so a failed acknowledgement never leaves a
        // cursor advertising only part of an accepted batch.
        try self.known.ranges.ensureTotalCapacity(self.known.allocator, required[0]);
        for (batch.changes.items) |change| try self.known.add(change.id);
    }
};

const Event = struct {
    change: Change,

    fn deinit(self: *Event, allocator: std.mem.Allocator) void {
        self.change.deinit(allocator);
    }
};

const EventMetadata = struct {
    inserted: std.ArrayList(InsertedElement) = .empty,
    deleted: std.ArrayList(ElementId) = .empty,

    fn deinit(self: *EventMetadata, allocator: std.mem.Allocator) void {
        self.inserted.deinit(allocator);
        self.deleted.deinit(allocator);
    }
};

/// The index-based operation that a newly accepted event contributes to the
/// already-rendered document.  A delete may become a set of individual
/// positions when concurrent deletes have removed some of its targets.
const TransformedOperation = struct {
    insert_index: ?usize = null,
    delete_positions: std.ArrayList(usize) = .empty,
};

pub const Replica = struct {
    allocator: std.mem.Allocator,
    actor: ActorId,
    ordering: Ordering = .fugue_max,
    next_counter: u64 = 0,
    events: std.ArrayList(Event) = .empty,
    event_index: std.AutoHashMap(OpId, usize),
    pending: std.ArrayList(Change) = .empty,
    pending_index: std.AutoHashMap(OpId, usize),
    frontier: std.ArrayList(OpId) = .empty,
    visible: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, actor: ActorId) !*Replica {
        return initWithOrdering(allocator, actor, .fugue_max);
    }

    /// Construct a replica with an explicit sequence ordering.  Native users
    /// should normally keep the FugueMax default; plain Fugue exists for
    /// reproducing older Eg-walker/YjsMod traces exactly.
    pub fn initWithOrdering(allocator: std.mem.Allocator, actor: ActorId, ordering: Ordering) !*Replica {
        const self = try allocator.create(Replica);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .actor = actor,
            .ordering = ordering,
            .event_index = std.AutoHashMap(OpId, usize).init(allocator),
            .pending_index = std.AutoHashMap(OpId, usize).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *Replica) void {
        for (self.events.items) |*event| event.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.event_index.deinit();

        for (self.pending.items) |pending_change| pending_change.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.pending_index.deinit();

        self.frontier.deinit(self.allocator);
        self.visible.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn text(self: *const Replica, allocator: std.mem.Allocator) ![]u8 {
        return allocator.dupe(u8, self.visible.items);
    }

    /// Borrow the current UTF-8 bytes without allocating. The slice remains
    /// valid until the next mutating call on this replica or `deinit`.
    pub fn textView(self: *const Replica) []const u8 {
        return self.visible.items;
    }

    /// Return the durable actor identity used for locally-created changes.
    /// The returned value is copied and therefore remains valid across later
    /// mutations.
    pub fn actorId(self: *const Replica) ActorId {
        return self.actor;
    }

    /// Return the sequence ordering selected for this replica.  Replicas that
    /// exchange changes must use the same mode.
    pub fn orderingMode(self: *const Replica) Ordering {
        return self.ordering;
    }

    /// Return the number of visible Unicode scalars without allocating.
    pub fn visibleScalarCount(self: *const Replica) usize {
        return self.visibleCount();
    }

    /// Return whether an ID belongs to accepted history.  Pending changes are
    /// deliberately excluded because they are not part of the document
    /// version yet.
    pub fn hasChange(self: *const Replica, change_id: OpId) bool {
        return self.findEvent(change_id) != null;
    }

    /// Return a no-allocation diagnostic snapshot of the current state.
    pub fn stats(self: *const Replica) ReplicaStats {
        return .{
            .actor = self.actor,
            .ordering = self.ordering,
            .next_counter = self.next_counter,
            .history_events = self.events.items.len,
            .pending_events = self.pending.items.len,
            .frontier_heads = self.frontier.items.len,
            .text_bytes = self.visible.items.len,
            .text_scalars = self.visibleScalarCount(),
        };
    }

    pub fn historyCount(self: *const Replica) usize {
        return self.events.items.len;
    }

    pub fn pendingCount(self: *const Replica) usize {
        return self.pending.items.len;
    }

    /// Borrow the canonical sorted frontier. The slice is invalidated by the
    /// next mutating call or by `deinit`.
    pub fn frontierView(self: *const Replica) []const OpId {
        return self.frontier.items;
    }

    /// Build a sparse per-actor summary of accepted event IDs. Pending
    /// changes are deliberately omitted; they are not yet part of the
    /// document version represented by the frontier.
    pub fn have(self: *const Replica, allocator: std.mem.Allocator) !Have {
        var result = Have.init(allocator);
        errdefer result.deinit();
        for (self.events.items) |event| {
            try result.add(event.change.id);
        }
        return result;
    }

    /// Encode the accepted-state summary for transport. The returned bytes
    /// are owned by the caller and can be passed to `Have.decode` on the peer.
    pub fn encodeHave(self: *const Replica, allocator: std.mem.Allocator) ![]u8 {
        var summary = try self.have(allocator);
        defer summary.deinit();
        return summary.encode(allocator);
    }

    pub fn version(self: *const Replica, allocator: std.mem.Allocator) !Version {
        var result = Version{};
        errdefer result.deinit(allocator);
        try result.frontier.appendSlice(allocator, self.frontier.items);
        return result;
    }

    /// Return the causal event IDs present in one version but not the other.
    /// The result is ordered by the same deterministic topological order used
    /// by replay and changesSince, so it can directly drive a future
    /// retreat/advance walker.
    pub fn diff(
        self: *const Replica,
        from: *const Version,
        to: *const Version,
        allocator: std.mem.Allocator,
    ) !VersionDiff {
        const from_included = try self.includedForVersion(from, allocator);
        defer allocator.free(from_included);
        const to_included = try self.includedForVersion(to, allocator);
        defer allocator.free(to_included);
        const order = try self.topologicalOrder(allocator);
        defer allocator.free(order);

        var result = VersionDiff{};
        errdefer result.deinit(allocator);
        for (order) |event_index| {
            if (from_included[event_index] and !to_included[event_index]) {
                try result.only_from.append(allocator, self.events.items[event_index].change.id);
            }
            if (to_included[event_index] and !from_included[event_index]) {
                try result.only_to.append(allocator, self.events.items[event_index].change.id);
            }
        }
        return result;
    }

    pub fn change(self: *const Replica, change_id: OpId, allocator: std.mem.Allocator) !Change {
        const event_index = self.findEvent(change_id) orelse return error.UnknownChange;
        return try self.events.items[event_index].change.clone(allocator);
    }

    pub fn insert(self: *Replica, index: usize, text_bytes: []const u8) !OpId {
        if (self.next_counter == std.math.maxInt(u64)) return error.CounterExhausted;
        _ = std.unicode.utf8CountCodepoints(text_bytes) catch return error.InvalidUtf8;
        if (index > self.visibleCount()) return error.IndexOutOfBounds;

        var operation = try Operation.initInsert(self.allocator, index, text_bytes);
        var operation_owned = true;
        errdefer if (operation_owned) operation.deinit(self.allocator);
        const new_id = OpId{ .actor = self.actor, .counter = self.next_counter };
        var local_change = try Change.initOwned(self.allocator, new_id, self.frontier.items, operation);
        operation_owned = false;
        defer local_change.deinit(self.allocator);

        try self.storeChange(&local_change);
        self.next_counter += 1;
        return new_id;
    }

    pub fn delete(self: *Replica, index: usize, length: usize) !OpId {
        if (self.next_counter == std.math.maxInt(u64)) return error.CounterExhausted;
        const visible_count = self.visibleCount();
        if (index > visible_count or length > visible_count - index) {
            return error.IndexOutOfBounds;
        }

        const new_id = OpId{ .actor = self.actor, .counter = self.next_counter };
        var local_change = try Change.init(
            self.allocator,
            new_id,
            self.frontier.items,
            Operation.initDelete(index, length),
        );
        defer local_change.deinit(self.allocator);

        try self.storeChange(&local_change);
        self.next_counter += 1;
        return new_id;
    }

    /// Apply several local edits as one atomic API call.  Each generated
    /// change is still an ordinary immutable event (and may be transported
    /// independently), but callers never observe a partially applied group:
    /// an invalid edit or allocation failure leaves this replica unchanged.
    /// Edit positions are interpreted against the text produced by preceding
    /// edits in the same group.
    pub fn applyGroup(self: *Replica, edits: []const Edit, allocator: std.mem.Allocator) !ChangeBatch {
        var result = ChangeBatch{};
        errdefer result.deinit(allocator);
        if (edits.len == 0) return result;

        var candidate = try self.cloneForReplay();
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit();

        const ids = try allocator.alloc(OpId, edits.len);
        defer allocator.free(ids);
        for (edits, 0..) |edit, i| {
            ids[i] = switch (edit) {
                .insert => |insert_edit| try candidate.insert(insert_edit.index, insert_edit.text),
                .delete => |delete_edit| try candidate.delete(delete_edit.index, delete_edit.length),
            };
        }

        for (ids) |change_id| {
            var copied = try candidate.change(change_id, allocator);
            var moved = false;
            errdefer if (!moved) copied.deinit(allocator);
            try result.changes.append(allocator, copied);
            moved = true;
        }

        const old = self.*;
        self.* = candidate.*;
        candidate.* = old;
        candidate.deinit();
        candidate_owned = false;
        return result;
    }

    pub fn receive(self: *Replica, incoming: *const Change) !ReceiveResult {
        try validateChange(incoming);

        if (self.findEvent(incoming.id)) |event_index| {
            if (!changesEqual(&self.events.items[event_index].change, incoming)) {
                return error.ConflictingDuplicate;
            }
            return .duplicate;
        }

        if (self.findPending(incoming.id)) |pending_index| {
            if (!changesEqual(&self.pending.items[pending_index], incoming)) {
                return error.ConflictingDuplicate;
            }
            return .pending;
        }

        try self.ensureObservedCounter(incoming.id);

        if (!self.parentsKnown(incoming.parents.items)) {
            const copy = try incoming.clone(self.allocator);
            errdefer copy.deinit(self.allocator);
            try self.pending_index.ensureTotalCapacity(@intCast(self.pending.items.len + 1));
            try self.pending.append(self.allocator, copy);
            self.pending_index.putAssumeCapacity(incoming.id, self.pending.items.len - 1);
            self.observeCounter(incoming.id);
            return .pending;
        }

        try self.storeChange(incoming);
        self.observeCounter(incoming.id);
        try self.drainPending();
        return .applied;
    }

    pub fn changesSince(
        self: *const Replica,
        known: *const Version,
        allocator: std.mem.Allocator,
    ) !std.ArrayList(Change) {
        const included = try self.includedForVersion(known, allocator);
        defer allocator.free(included);
        const order = try self.topologicalOrder(allocator);
        defer allocator.free(order);

        var result: std.ArrayList(Change) = .empty;
        errdefer {
            for (result.items) |result_change| result_change.deinit(allocator);
            result.deinit(allocator);
        }

        for (order) |i| {
            if (included[i]) continue;
            var cloned = try self.events.items[i].change.clone(allocator);
            var moved = false;
            errdefer if (!moved) cloned.deinit(allocator);
            try result.append(allocator, cloned);
            moved = true;
        }
        return result;
    }

    /// Return accepted changes whose IDs are not represented by `known`.
    /// Changes are dependency-closed because the result follows a
    /// deterministic topological order: an unknown parent is emitted before
    /// its unknown child. A Have containing a child but not its parent is
    /// therefore repaired by sending the missing parent as well.
    pub fn changesForHave(
        self: *const Replica,
        known: *const Have,
        allocator: std.mem.Allocator,
    ) !std.ArrayList(Change) {
        const order = try self.topologicalOrder(allocator);
        defer allocator.free(order);

        var result: std.ArrayList(Change) = .empty;
        errdefer {
            for (result.items) |result_change| result_change.deinit(allocator);
            result.deinit(allocator);
        }

        for (order) |event_index| {
            const event = &self.events.items[event_index];
            if (known.contains(event.change.id)) continue;
            var cloned = try event.change.clone(allocator);
            var moved = false;
            errdefer if (!moved) cloned.deinit(allocator);
            try result.append(allocator, cloned);
            moved = true;
        }
        return result;
    }

    pub fn save(self: *const Replica, allocator: std.mem.Allocator) ![]u8 {
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(allocator);

        try bytes.appendSlice(allocator, "CRDTREF\x00");
        try bytes.append(allocator, 2);
        try bytes.append(allocator, @intFromEnum(self.ordering));
        try bytes.appendSlice(allocator, &self.actor);
        try appendU64(&bytes, allocator, self.next_counter);
        try appendVarint(&bytes, allocator, self.events.items.len);
        try appendVarint(&bytes, allocator, self.pending.items.len);

        const order = try self.topologicalOrder(allocator);
        defer allocator.free(order);
        for (order) |event_index| {
            const event = &self.events.items[event_index];
            var frame: std.ArrayList(u8) = .empty;
            defer frame.deinit(allocator);
            try encodeChange(&frame, allocator, &event.change);
            try appendVarint(&bytes, allocator, frame.items.len);
            try bytes.appendSlice(allocator, frame.items);
            try appendU32(&bytes, allocator, std.hash.crc.Crc32.hash(frame.items));
        }

        const pending_order = try allocator.alloc(usize, self.pending.items.len);
        defer allocator.free(pending_order);
        for (pending_order, 0..) |*pending_index, i| pending_index.* = i;
        std.sort.heap(usize, pending_order, self, lessPendingIndex);
        for (pending_order) |pending_index| {
            const pending_change = &self.pending.items[pending_index];
            var frame: std.ArrayList(u8) = .empty;
            defer frame.deinit(allocator);
            try encodeChange(&frame, allocator, pending_change);
            try appendVarint(&bytes, allocator, frame.items.len);
            try bytes.appendSlice(allocator, frame.items);
            try appendU32(&bytes, allocator, std.hash.crc.Crc32.hash(frame.items));
        }

        return bytes.toOwnedSlice(allocator);
    }

    pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !*Replica {
        return loadWithOptions(allocator, bytes, .{});
    }

    /// Decode a persisted replica with explicit resource limits. Validation
    /// happens before each corresponding allocation, and a failure destroys
    /// any partially decoded replica before returning.
    pub fn loadWithOptions(
        allocator: std.mem.Allocator,
        bytes: []const u8,
        options: LoadOptions,
    ) !*Replica {
        if (bytes.len > options.max_input_bytes) return error.InputTooLarge;
        var cursor: usize = 0;
        if (bytes.len < 34 or !std.mem.eql(u8, bytes[0..8], "CRDTREF\x00")) return error.InvalidFormat;
        cursor = 8;
        if (try readByte(bytes, &cursor) != 2) return error.UnsupportedFormat;
        const ordering = switch (try readByte(bytes, &cursor)) {
            0 => Ordering.fugue,
            1 => Ordering.fugue_max,
            else => return error.InvalidFormat,
        };

        var actor: ActorId = undefined;
        const actor_bytes = try readBytes(bytes, &cursor, actor.len);
        @memcpy(&actor, actor_bytes);
        const next_counter = try readU64(bytes, &cursor);
        const event_count = try readVarint(bytes, &cursor);
        const pending_count = try readVarint(bytes, &cursor);
        if (event_count > options.max_events) return error.TooManyEvents;
        if (pending_count > options.max_pending) return error.TooManyPending;

        var replica = try Replica.initWithOrdering(allocator, actor, ordering);
        errdefer replica.deinit();

        var event_index: usize = 0;
        while (event_index < event_count) : (event_index += 1) {
            const frame_len = try readVarint(bytes, &cursor);
            if (frame_len > options.max_frame_bytes) return error.FrameTooLarge;
            const frame = try readBytes(bytes, &cursor, frame_len);
            const checksum = try readU32(bytes, &cursor);
            if (std.hash.crc.Crc32.hash(frame) != checksum) return error.ChecksumMismatch;

            var frame_cursor: usize = 0;
            var decoded = try decodeChange(allocator, frame, &frame_cursor, options);
            defer decoded.deinit(allocator);
            if (frame_cursor != frame.len) return error.InvalidFormat;
            const result = try replica.receive(&decoded);
            if (result != .applied) return error.InvalidFormat;
        }

        var pending_index: usize = 0;
        while (pending_index < pending_count) : (pending_index += 1) {
            const frame_len = try readVarint(bytes, &cursor);
            if (frame_len > options.max_frame_bytes) return error.FrameTooLarge;
            const frame = try readBytes(bytes, &cursor, frame_len);
            const checksum = try readU32(bytes, &cursor);
            if (std.hash.crc.Crc32.hash(frame) != checksum) return error.ChecksumMismatch;

            var frame_cursor: usize = 0;
            var decoded = try decodeChange(allocator, frame, &frame_cursor, options);
            defer decoded.deinit(allocator);
            if (frame_cursor != frame.len) return error.InvalidFormat;
            const result = try replica.receive(&decoded);
            // The pending section is a persisted statement that these
            // records were not yet admissible.  Accepting an applied record
            // here would silently normalize a corrupt snapshot into a
            // different state; duplicates are invalid for the same reason.
            if (result != .pending) return error.InvalidFormat;
        }

        if (cursor != bytes.len) return error.InvalidFormat;
        if (next_counter > replica.next_counter) replica.next_counter = next_counter;
        return replica;
    }

    /// Replay an append-only `ChangeLog` stream. Complete frames are decoded
    /// and validated first, then applied to a cloned replica; the clone is
    /// committed only if every change succeeds. This keeps malformed or
    /// semantically invalid logs from partially mutating the destination.
    pub fn replayLog(self: *Replica, bytes: []const u8, options: ReplayOptions) !ReplayResult {
        if (bytes.len > options.limits.max_input_bytes) return error.InputTooLarge;

        var decoded_changes: std.ArrayList(Change) = .empty;
        defer {
            for (decoded_changes.items) |decoded_change| decoded_change.deinit(self.allocator);
            decoded_changes.deinit(self.allocator);
        }

        var cursor: usize = 0;
        var recovered_tail = false;
        while (cursor < bytes.len) {
            if (decoded_changes.items.len >= options.limits.max_log_frames) {
                return error.TooManyLogFrames;
            }
            const frame_start = cursor;
            const frame_len = readVarint(bytes, &cursor) catch |err| {
                if (err == error.UnexpectedEnd and options.tail_policy == .recover) {
                    cursor = frame_start;
                    recovered_tail = true;
                    break;
                }
                return err;
            };
            if (frame_len > options.limits.max_frame_bytes) return error.FrameTooLarge;

            const frame = readBytes(bytes, &cursor, frame_len) catch |err| {
                if (err == error.UnexpectedEnd and options.tail_policy == .recover) {
                    cursor = frame_start;
                    recovered_tail = true;
                    break;
                }
                return err;
            };
            const checksum = readU32(bytes, &cursor) catch |err| {
                if (err == error.UnexpectedEnd and options.tail_policy == .recover) {
                    cursor = frame_start;
                    recovered_tail = true;
                    break;
                }
                return err;
            };
            if (std.hash.crc.Crc32.hash(frame) != checksum) return error.ChecksumMismatch;

            var frame_cursor: usize = 0;
            var decoded = try decodeChange(self.allocator, frame, &frame_cursor, options.limits);
            var moved = false;
            errdefer if (!moved) decoded.deinit(self.allocator);
            if (frame_cursor != frame.len) return error.InvalidFormat;
            try decoded_changes.append(self.allocator, decoded);
            moved = true;
        }

        if (decoded_changes.items.len == 0) {
            return .{
                .consumed_bytes = cursor,
                .recovered_tail = recovered_tail,
                .pending = self.pending.items.len,
            };
        }

        var candidate = try self.cloneForReplay();
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit();

        var applied: usize = 0;
        var duplicates: usize = 0;
        for (decoded_changes.items) |*decoded_change| {
            switch (try candidate.receive(decoded_change)) {
                .applied => applied += 1,
                .duplicate => duplicates += 1,
                .pending => {},
            }
        }

        const pending = candidate.pending.items.len;
        const old = self.*;
        self.* = candidate.*;
        candidate.* = old;
        candidate.deinit();
        candidate_owned = false;

        return .{
            .frames = decoded_changes.items.len,
            .applied = applied,
            .duplicates = duplicates,
            .pending = pending,
            .consumed_bytes = cursor,
            .recovered_tail = recovered_tail,
        };
    }

    fn cloneForReplay(self: *const Replica) !*Replica {
        var copy = try Replica.initWithOrdering(self.allocator, self.actor, self.ordering);
        errdefer copy.deinit();
        copy.next_counter = self.next_counter;

        try copy.frontier.appendSlice(self.allocator, self.frontier.items);
        try copy.visible.appendSlice(self.allocator, self.visible.items);

        for (self.events.items) |event| {
            const event_id = event.change.id;
            var cloned = try event.change.clone(self.allocator);
            var moved = false;
            errdefer if (!moved) cloned.deinit(self.allocator);
            try copy.events.append(self.allocator, .{ .change = cloned });
            moved = true;
            try copy.event_index.put(event_id, copy.events.items.len - 1);
        }
        for (self.pending.items) |pending_change| {
            const pending_id = pending_change.id;
            var cloned = try pending_change.clone(self.allocator);
            var moved = false;
            errdefer if (!moved) cloned.deinit(self.allocator);
            try copy.pending.append(self.allocator, cloned);
            moved = true;
            try copy.pending_index.put(pending_id, copy.pending.items.len - 1);
        }
        return copy;
    }

    fn visibleCount(self: *const Replica) usize {
        return std.unicode.utf8CountCodepoints(self.visible.items) catch unreachable;
    }

    /// Apply an operation to the cached plain-text state without constructing
    /// the temporary CRDT. This is valid only when the operation's parents
    /// equal the current frontier, which is the critical-version fast path:
    /// no concurrent event can shift or tombstone its target.
    fn applyOriginalToVisible(self: *const Replica, operation: Operation) !std.ArrayList(u8) {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);

        switch (operation) {
            .insert => |ins| {
                _ = std.unicode.utf8CountCodepoints(ins.text) catch return error.InvalidUtf8;
                if (ins.index > self.visibleCount()) return error.InvalidOperation;
                const byte_index = try scalarByteOffset(self.visible.items, ins.index);
                try result.ensureTotalCapacity(self.allocator, self.visible.items.len + ins.text.len);
                try result.appendSlice(self.allocator, self.visible.items[0..byte_index]);
                try result.appendSlice(self.allocator, ins.text);
                try result.appendSlice(self.allocator, self.visible.items[byte_index..]);
            },
            .delete => |del| {
                const count = self.visibleCount();
                if (del.index > count or del.length > count - del.index) {
                    return error.InvalidOperation;
                }
                const start_byte = try scalarByteOffset(self.visible.items, del.index);
                const end_byte = try scalarByteOffset(self.visible.items, del.index + del.length);
                try result.ensureTotalCapacity(self.allocator, self.visible.items.len - (end_byte - start_byte));
                try result.appendSlice(self.allocator, self.visible.items[0..start_byte]);
                try result.appendSlice(self.allocator, self.visible.items[end_byte..]);
            },
        }
        return result;
    }

    fn includedForVersion(self: *const Replica, known: *const Version, allocator: std.mem.Allocator) ![]bool {
        return self.includedForFrontier(known.frontier.items, allocator);
    }

    fn includedForFrontier(self: *const Replica, frontier: []const OpId, allocator: std.mem.Allocator) ![]bool {
        const included = try allocator.alloc(bool, self.events.items.len);
        var stack: std.ArrayList(usize) = .empty;
        errdefer {
            stack.deinit(allocator);
            allocator.free(included);
        }
        try self.fillIncludedForFrontier(frontier, included, &stack, allocator);
        stack.deinit(allocator);
        return included;
    }

    fn fillIncludedForFrontier(
        self: *const Replica,
        frontier: []const OpId,
        included: []bool,
        stack: *std.ArrayList(usize),
        allocator: std.mem.Allocator,
    ) !void {
        @memset(included, false);
        stack.clearRetainingCapacity();
        for (frontier) |frontier_id| {
            if (self.findEvent(frontier_id)) |event_index| {
                try stack.append(allocator, event_index);
            }
        }

        while (stack.pop()) |event_index| {
            if (included[event_index]) continue;
            included[event_index] = true;
            for (self.events.items[event_index].change.parents.items) |parent| {
                if (self.findEvent(parent)) |parent_index| try stack.append(allocator, parent_index);
            }
        }
    }

    fn storeChange(self: *Replica, source: *const Change) !void {
        if (!self.parentsKnown(source.parents.items)) return error.MissingParent;
        try self.validateFrontier(source.parents.items);

        const can_apply_original = frontiersEqual(source.parents.items, self.frontier.items);

        // Advancing a frontier can only increase its storage by one entry.
        // Reserve before mutating either the graph or the frontier so an
        // allocation failure leaves the replica unchanged.
        try self.frontier.ensureTotalCapacity(self.allocator, self.frontier.items.len + 1);
        try self.events.ensureTotalCapacity(self.allocator, self.events.items.len + 1);
        try self.event_index.ensureTotalCapacity(@intCast(self.events.items.len + 1));
        // The reservation above may move the frontier buffer. Capture this
        // slice only after all reservations and before the frontier mutates.
        const old_frontier = self.frontier.items;

        var owned = try source.clone(self.allocator);
        var moved = false;
        errdefer if (!moved) owned.deinit(self.allocator);

        const event_index = self.events.items.len;
        if (can_apply_original) {
            // `applyOriginalToVisible` is the final fallible step. Once it
            // succeeds, all graph/frontier operations below use reserved
            // capacity and cannot leave a half-applied edit.
            const next_visible = try self.applyOriginalToVisible(source.operation);
            self.events.appendAssumeCapacity(.{ .change = owned });
            moved = true;
            self.event_index.putAssumeCapacity(source.id, event_index);
            self.advanceFrontier(source.id, source.parents.items);
            self.visible.deinit(self.allocator);
            self.visible = next_visible;
            return;
        }

        self.events.appendAssumeCapacity(.{ .change = owned });
        moved = true;
        self.event_index.putAssumeCapacity(source.id, event_index);
        errdefer {
            var removed = self.events.pop().?;
            removed.deinit(self.allocator);
            _ = self.event_index.remove(source.id);
        }

        const next_visible = self.rebuildCritical(source, old_frontier) catch |err| switch (err) {
            // The critical cut finder is intentionally conservative.  A
            // graph it cannot prove safe still uses the already-tested full
            // walker; correctness never depends on the optimization.
            error.NotApplicable => {
                try self.rebuild();
                self.advanceFrontier(source.id, source.parents.items);
                return;
            },
            else => return err,
        };
        self.visible.deinit(self.allocator);
        self.visible = next_visible;
        self.advanceFrontier(source.id, source.parents.items);
    }

    /// A causal frontier is a set of maximal known events. Syntactic
    /// validation cannot detect a dominated pair because it has no graph;
    /// perform that semantic check only once every parent is present.
    fn validateFrontier(self: *const Replica, parents: []const OpId) !void {
        if (parents.len < 2) return;

        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch = scratch_arena.allocator();
        var stack: std.ArrayList(usize) = .empty;
        defer stack.deinit(scratch);

        for (parents, 0..) |left, i| {
            for (parents[i + 1 ..]) |right| {
                if (try self.isAncestorWithStack(left, right, &stack, scratch) or
                    try self.isAncestorWithStack(right, left, &stack, scratch))
                {
                    return error.InvalidParents;
                }
            }
        }
    }

    fn isAncestorWithStack(
        self: *const Replica,
        ancestor: OpId,
        descendant: OpId,
        stack: *std.ArrayList(usize),
        allocator: std.mem.Allocator,
    ) !bool {
        const descendant_index = self.findEvent(descendant) orelse return false;
        stack.clearRetainingCapacity();
        try stack.append(allocator, descendant_index);

        while (stack.pop()) |event_index| {
            for (self.events.items[event_index].change.parents.items) |parent| {
                if (parent.eql(ancestor)) return true;
                if (self.findEvent(parent)) |parent_index| {
                    try stack.append(allocator, parent_index);
                }
            }
        }
        return false;
    }

    fn drainPending(self: *Replica) !void {
        var made_progress = true;
        while (made_progress) {
            made_progress = false;
            var i: usize = 0;
            while (i < self.pending.items.len) {
                if (!self.parentsKnown(self.pending.items[i].parents.items)) {
                    i += 1;
                    continue;
                }

                const ready = self.pending.items[i];
                try self.storeChange(&ready);
                const removed = self.pending.orderedRemove(i);
                removed.deinit(self.allocator);
                _ = self.pending_index.remove(ready.id);
                for (self.pending.items[i..], i..) |pending_change, shifted_index| {
                    self.pending_index.putAssumeCapacity(pending_change.id, shifted_index);
                }
                made_progress = true;
            }
        }
    }

    fn findEvent(self: *const Replica, wanted: OpId) ?usize {
        return self.event_index.get(wanted);
    }

    fn findPending(self: *const Replica, wanted: OpId) ?usize {
        return self.pending_index.get(wanted);
    }

    fn parentsKnown(self: *const Replica, parents: []const OpId) bool {
        for (parents) |parent| {
            if (self.findEvent(parent) == null) return false;
        }
        return true;
    }

    fn ensureObservedCounter(self: *const Replica, incoming: OpId) !void {
        if (!std.mem.eql(u8, &incoming.actor, &self.actor)) return;
        if (incoming.counter == std.math.maxInt(u64)) return error.CounterExhausted;
    }

    fn observeCounter(self: *Replica, incoming: OpId) void {
        if (!std.mem.eql(u8, &incoming.actor, &self.actor)) return;
        const successor = incoming.counter + 1;
        if (successor > self.next_counter) self.next_counter = successor;
    }

    fn advanceFrontier(self: *Replica, new_id: OpId, parents: []const OpId) void {
        var i: usize = 0;
        while (i < self.frontier.items.len) {
            if (containsOp(parents, self.frontier.items[i])) {
                _ = self.frontier.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        // Capacity was reserved by storeChange before the graph mutation.
        self.frontier.appendAssumeCapacity(new_id);
        std.sort.heap(OpId, self.frontier.items, {}, lessOpId);
    }

    fn rebuild(self: *Replica) !void {
        return self.rebuildWalker();
    }

    /// Reconstruct only the suffix after a conservative critical version and
    /// transform `source` onto the currently rendered document.  This is the
    /// state-clearing optimization described by Eg-walker: the old prefix is
    /// represented by anonymous placeholder records, while the temporary
    /// CRDT is discarded as soon as the one transformed operation is known.
    ///
    /// `NotApplicable` is deliberately part of this helper's contract.  It
    /// means that the inexpensive proof of a critical cut did not succeed;
    /// the caller then falls back to the exhaustive walker.
    fn rebuildCritical(self: *Replica, source: *const Change, old_frontier: []const OpId) !std.ArrayList(u8) {
        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch = scratch_arena.allocator();

        const order = try self.topologicalOrder(scratch);
        defer scratch.free(order);

        const common = try scratch.alloc(bool, self.events.items.len);
        const old_included = try scratch.alloc(bool, self.events.items.len);
        const new_included = try scratch.alloc(bool, self.events.items.len);
        @memset(common, true);

        var closure_stack: std.ArrayList(usize) = .empty;
        defer closure_stack.deinit(scratch);

        // The common prefix is Events(old_frontier) ∩
        // Events(source.parents).  An empty version contributes the empty
        // set, so handle it explicitly rather than leaving `common` true.
        if (old_frontier.len == 0) {
            @memset(common, false);
        } else {
            try self.fillIncludedForFrontier(old_frontier, old_included, &closure_stack, scratch);
            for (common, old_included) |*is_common, in_old| is_common.* = is_common.* and in_old;
        }
        if (source.parents.items.len == 0) {
            @memset(common, false);
        } else {
            try self.fillIncludedForFrontier(source.parents.items, new_included, &closure_stack, scratch);
            for (common, new_included) |*is_common, in_new| is_common.* = is_common.* and in_new;
        }

        const common_frontier = try self.criticalFrontier(common, order, scratch);

        // Prove the defining property of a critical version: every event
        // outside its causal closure happened after every frontier tip.
        // If this test fails, using placeholders would be unsound, so use the
        // already-tested full replay instead.
        for (order) |event_index| {
            if (common[event_index]) continue;
            const event_id = self.events.items[event_index].change.id;
            for (common_frontier.items) |critical_tip| {
                if (!try self.isAncestorWithStack(critical_tip, event_id, &closure_stack, scratch)) {
                    return error.NotApplicable;
                }
            }
        }
        for (common_frontier.items) |critical_tip| {
            if (!try self.isAncestorWithStack(critical_tip, source.id, &closure_stack, scratch)) {
                return error.NotApplicable;
            }
        }

        const placeholder_count = try self.requiredPlaceholderCount(source, common_frontier.items.len != 0);
        var walked = try MergeIndex.initWithOrdering(scratch, self.ordering);
        errdefer walked.deinit();

        const placeholder_actor = [_]u8{0xff} ** 16;
        var placeholder_index: usize = 0;
        while (placeholder_index < placeholder_count) : (placeholder_index += 1) {
            if (placeholder_index > std.math.maxInt(u64)) return error.NotApplicable;
            try walked.insertPlaceholder(.{
                .op = .{ .actor = placeholder_actor, .counter = @intCast(placeholder_index) },
                .offset = 0,
                .placeholder = true,
            });
        }

        const metadata = try scratch.alloc(EventMetadata, self.events.items.len);
        for (metadata) |*event_metadata| event_metadata.* = .{};

        const current_included = try scratch.alloc(bool, self.events.items.len);
        const parent_included = try scratch.alloc(bool, self.events.items.len);
        var current_frontier: std.ArrayList(OpId) = .empty;
        try current_frontier.appendSlice(scratch, common_frontier.items);

        // First reconstruct the complete known graph's temporary effect state.
        // We skip only the newly accepted event; its transformed operation is
        // produced separately below.  The effect state therefore corresponds
        // exactly to the cached text at `old_frontier`.
        for (order) |event_index| {
            if (common[event_index]) continue;
            const event = &self.events.items[event_index];
            if (event.change.id.eql(source.id)) continue;

            try self.movePrepare(
                walked,
                metadata,
                current_frontier.items,
                event.change.parents.items,
                order,
                current_included,
                parent_included,
                &closure_stack,
                scratch,
            );
            try self.applyWalkerEvent(walked, &metadata[event_index], &event.change, scratch);
            current_frontier.clearRetainingCapacity();
            try current_frontier.append(scratch, event.change.id);
        }

        // The loop ends at an arbitrary topological tip.  Restore the prepare
        // view to the actual cached version, then move it to the new event's
        // parent version before interpreting the original index.
        try self.movePrepare(
            walked,
            metadata,
            current_frontier.items,
            old_frontier,
            order,
            current_included,
            parent_included,
            &closure_stack,
            scratch,
        );
        current_frontier.clearRetainingCapacity();
        try current_frontier.appendSlice(scratch, old_frontier);
        try self.movePrepare(
            walked,
            metadata,
            current_frontier.items,
            source.parents.items,
            order,
            current_included,
            parent_included,
            &closure_stack,
            scratch,
        );

        const source_index = self.findEvent(source.id) orelse return error.UnknownChange;
        var transformed = try self.applyWalkerEventTransformed(
            walked,
            &metadata[source_index],
            source,
            scratch,
        );
        std.sort.heap(usize, transformed.delete_positions.items, {}, lessUsize);
        return self.applyTransformedToVisible(&transformed, source.operation);
    }

    fn criticalFrontier(
        self: *const Replica,
        common: []const bool,
        order: []const usize,
        allocator: std.mem.Allocator,
    ) !std.ArrayList(OpId) {
        var has_common_child = try allocator.alloc(bool, self.events.items.len);
        @memset(has_common_child, false);

        for (self.events.items, 0..) |event, event_index| {
            if (!common[event_index]) continue;
            for (event.change.parents.items) |parent| {
                if (self.findEvent(parent)) |parent_index| {
                    if (common[parent_index]) has_common_child[parent_index] = true;
                }
            }
        }

        var result: std.ArrayList(OpId) = .empty;
        for (order) |event_index| {
            if (common[event_index] and !has_common_child[event_index]) {
                try result.append(allocator, self.events.items[event_index].change.id);
            }
        }
        std.sort.heap(OpId, result.items, {}, lessOpId);
        return result;
    }

    fn requiredPlaceholderCount(self: *const Replica, source: *const Change, has_known_prefix: bool) !usize {
        if (!has_known_prefix) return 0;

        var required: usize = 0;
        var total_deletes: usize = 0;

        const consider = struct {
            fn run(operation: Operation, required_count: *usize, delete_count: *usize) !void {
                const index = switch (operation) {
                    .insert => |insert_operation| insert_operation.index,
                    .delete => |delete_operation| delete_operation.index,
                };
                const index_requirement = @addWithOverflow(index, @as(usize, 1));
                if (index_requirement[1] != 0) return error.NotApplicable;
                if (index_requirement[0] > required_count.*) required_count.* = index_requirement[0];

                switch (operation) {
                    .insert => {},
                    .delete => |delete_operation| {
                        const next = @addWithOverflow(delete_count.*, delete_operation.length);
                        if (next[1] != 0) return error.NotApplicable;
                        delete_count.* = next[0];
                    },
                }
            }
        }.run;

        for (self.events.items) |event| try consider(event.change.operation, &required, &total_deletes);
        try consider(source.operation, &required, &total_deletes);

        const visible_plus_deletes = @addWithOverflow(self.visibleCount(), total_deletes);
        if (visible_plus_deletes[1] != 0) return error.NotApplicable;
        const conservative = @addWithOverflow(visible_plus_deletes[0], @as(usize, 1));
        if (conservative[1] != 0) return error.NotApplicable;
        if (conservative[0] > required) required = conservative[0];
        return required;
    }

    fn movePrepare(
        self: *const Replica,
        state: *MergeIndex,
        metadata: []const EventMetadata,
        current_frontier: []const OpId,
        target_frontier: []const OpId,
        order: []const usize,
        current_included: []bool,
        target_included: []bool,
        stack: *std.ArrayList(usize),
        allocator: std.mem.Allocator,
    ) !void {
        try self.fillIncludedForFrontier(current_frontier, current_included, stack, allocator);
        try self.fillIncludedForFrontier(target_frontier, target_included, stack, allocator);

        var retreat_index = order.len;
        while (retreat_index > 0) {
            retreat_index -= 1;
            const event_index = order[retreat_index];
            if (current_included[event_index] and !target_included[event_index]) {
                try retreatEvent(state, &metadata[event_index]);
            }
        }
        for (order) |event_index| {
            if (target_included[event_index] and !current_included[event_index]) {
                try advanceEvent(state, &metadata[event_index]);
            }
        }
    }

    fn applyWalkerEventTransformed(
        self: *const Replica,
        state: *MergeIndex,
        metadata: *EventMetadata,
        event_change: *const Change,
        metadata_allocator: std.mem.Allocator,
    ) !TransformedOperation {
        var transformed: TransformedOperation = .{};

        switch (event_change.operation) {
            .insert => |ins| {
                if (ins.index > state.visibleCount(.prepare)) return error.InvalidOperation;

                var scalar_it = (try std.unicode.Utf8View.init(ins.text)).iterator();
                var offset: u32 = 0;
                var first_inserted: ?ElementId = null;
                while (scalar_it.nextCodepointSlice()) |slice| {
                    const inserted = try state.insertAt(
                        .prepare,
                        ins.index + @as(usize, offset),
                        .{ .op = event_change.id, .offset = offset },
                        .fromBytes(slice),
                    );
                    try metadata.inserted.append(metadata_allocator, inserted);
                    if (first_inserted == null) first_inserted = inserted.id;
                    offset += 1;
                }

                if (first_inserted) |first| {
                    transformed.insert_index = try self.mapEffectBoundary(state, first, event_change.id);
                }
            },
            .delete => |del| {
                const visible_count = state.visibleCount(.prepare);
                if (del.index > visible_count or del.length > visible_count - del.index) {
                    return error.InvalidOperation;
                }

                var targets: std.ArrayList(ElementId) = .empty;
                defer targets.deinit(metadata_allocator);
                var remaining = del.length;
                while (remaining > 0) : (remaining -= 1) {
                    const target = state.visibleAt(.prepare, del.index) orelse return error.InvalidOperation;
                    try targets.append(metadata_allocator, target);
                    if (try state.isVisible(target, .effect)) {
                        try transformed.delete_positions.append(
                            metadata_allocator,
                            try self.mapEffectElement(state, target, event_change.id),
                        );
                    }
                    try state.advancePrepareDelete(target);
                }
                // All output positions were measured against the same effect
                // version (the current document).  Only after collecting
                // them do we apply this event's effect tombstones; otherwise
                // an earlier target would shift the mapped position of a
                // later target in a multi-scalar delete.
                for (targets.items) |target| {
                    try state.deleteEffect(target);
                    try metadata.deleted.append(metadata_allocator, target);
                }
            },
        }
        return transformed;
    }

    fn mapEffectBoundary(self: *const Replica, state: *const MergeIndex, target: ?ElementId, excluded: OpId) !usize {
        const target_index = if (target) |wanted| state.find(wanted) else null;
        if (target != null and target_index == null) return error.UnknownElement;

        var known_visible: usize = 0;
        for (state.items()) |entry| {
            if (!entry.effectVisible() or entry.placeholder or entry.id.op.eql(excluded)) continue;
            known_visible += 1;
        }
        const actual_count = self.visibleCount();
        if (known_visible > actual_count) return error.NotApplicable;
        const base_slots = actual_count - known_visible;

        var actual_index: usize = 0;
        var base_seen: usize = 0;
        var skipped_extra = false;
        for (state.items(), 0..) |entry, entry_index| {
            if (target_index) |wanted_index| {
                if (entry_index == wanted_index) break;
            }
            if (!entry.effectVisible()) continue;
            if (!entry.placeholder and entry.id.op.eql(excluded)) continue;

            if (entry.placeholder) {
                if (base_seen < base_slots) {
                    base_seen += 1;
                    actual_index += 1;
                } else {
                    skipped_extra = true;
                }
            } else {
                if (skipped_extra) return error.NotApplicable;
                actual_index += 1;
            }
        }

        if (target_index) |wanted_index| {
            const target_entry = state.items()[wanted_index];
            if (target_entry.placeholder and base_seen >= base_slots) return error.NotApplicable;
            if (!target_entry.placeholder and target_entry.id.op.eql(excluded)) {
                // A source insertion is a virtual record while mapping its
                // own output boundary; the boundary itself is valid.
            } else if (skipped_extra and !target_entry.placeholder) {
                return error.NotApplicable;
            }
        } else if (skipped_extra) {
            // Extra anonymous records may only be an unobserved tail.
        }

        if (actual_index > actual_count) return error.NotApplicable;
        if (target == null and actual_index != actual_count) return error.NotApplicable;
        return actual_index;
    }

    fn mapEffectElement(self: *const Replica, state: *const MergeIndex, target: ElementId, excluded: OpId) !usize {
        const target_index = state.find(target) orelse return error.UnknownElement;
        const target_entry = state.items()[target_index];
        if (!target_entry.effectVisible()) return error.NotApplicable;
        if (!target_entry.placeholder and target_entry.id.op.eql(excluded)) return error.NotApplicable;
        return self.mapEffectBoundary(state, target, excluded);
    }

    fn applyTransformedToVisible(self: *const Replica, transformed: *const TransformedOperation, operation: Operation) !std.ArrayList(u8) {
        switch (operation) {
            .insert => |ins| {
                const index = transformed.insert_index orelse return self.cloneVisible();
                if (index > self.visibleCount()) return error.NotApplicable;
                const byte_index = try scalarByteOffset(self.visible.items, index);
                var result: std.ArrayList(u8) = .empty;
                errdefer result.deinit(self.allocator);
                try result.ensureTotalCapacity(self.allocator, self.visible.items.len + ins.text.len);
                try result.appendSlice(self.allocator, self.visible.items[0..byte_index]);
                try result.appendSlice(self.allocator, ins.text);
                try result.appendSlice(self.allocator, self.visible.items[byte_index..]);
                return result;
            },
            .delete => {
                var result = try self.cloneVisible();
                errdefer result.deinit(self.allocator);

                var i = transformed.delete_positions.items.len;
                while (i > 0) {
                    i -= 1;
                    const scalar_index = transformed.delete_positions.items[i];
                    const count = std.unicode.utf8CountCodepoints(result.items) catch return error.InvalidUtf8;
                    if (scalar_index >= count) return error.NotApplicable;
                    const start_byte = try scalarByteOffset(result.items, scalar_index);
                    const end_byte = try scalarByteOffset(result.items, scalar_index + 1);
                    try result.replaceRange(self.allocator, start_byte, end_byte - start_byte, &.{});
                }
                return result;
            },
        }
    }

    fn cloneVisible(self: *const Replica) !std.ArrayList(u8) {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);
        try result.appendSlice(self.allocator, self.visible.items);
        return result;
    }

    /// Exhaustively replay the graph with Eg-walker's prepare/effect state
    /// transitions.  This remains the correctness fallback and differential
    /// oracle for the critical-version path above.
    fn rebuildWalker(self: *Replica) !void {
        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch = scratch_arena.allocator();

        const order = try self.topologicalOrder(scratch);
        defer scratch.free(order);

        const metadata = try scratch.alloc(EventMetadata, self.events.items.len);
        for (metadata) |*event_metadata| event_metadata.* = .{};

        var walked = try MergeIndex.initWithOrdering(scratch, self.ordering);
        errdefer walked.deinit();

        const current_included = try scratch.alloc(bool, self.events.items.len);
        const parent_included = try scratch.alloc(bool, self.events.items.len);
        var closure_stack: std.ArrayList(usize) = .empty;
        defer closure_stack.deinit(scratch);

        var current_frontier: [1]OpId = undefined;
        var current_frontier_len: usize = 0;
        for (order) |event_index| {
            try self.fillIncludedForFrontier(
                current_frontier[0..current_frontier_len],
                current_included,
                &closure_stack,
                scratch,
            );
            try self.fillIncludedForFrontier(
                self.events.items[event_index].change.parents.items,
                parent_included,
                &closure_stack,
                scratch,
            );

            // Retreat descendants first so a branch is removed in reverse
            // causal order, then advance ancestors in causal order.
            var retreat_index = order.len;
            while (retreat_index > 0) {
                retreat_index -= 1;
                const changed_index = order[retreat_index];
                if (current_included[changed_index] and !parent_included[changed_index]) {
                    try retreatEvent(walked, &metadata[changed_index]);
                }
            }
            for (order) |changed_index| {
                if (parent_included[changed_index] and !current_included[changed_index]) {
                    try advanceEvent(walked, &metadata[changed_index]);
                }
            }

            try self.applyWalkerEvent(
                walked,
                &metadata[event_index],
                &self.events.items[event_index].change,
                scratch,
            );
            current_frontier[0] = self.events.items[event_index].change.id;
            current_frontier_len = 1;
        }

        const rendered = try walked.render(self.allocator, .effect);
        var new_visible: std.ArrayList(u8) = .empty;
        new_visible.items = rendered;
        new_visible.capacity = rendered.len;
        self.visible.deinit(self.allocator);
        self.visible = new_visible;
    }

    fn applyWalkerEvent(
        _: *Replica,
        state: *MergeIndex,
        metadata: *EventMetadata,
        event_change: *const Change,
        metadata_allocator: std.mem.Allocator,
    ) !void {
        switch (event_change.operation) {
            .insert => |ins| {
                if (ins.index > state.visibleCount(.prepare)) return error.InvalidOperation;

                var scalar_it = (try std.unicode.Utf8View.init(ins.text)).iterator();
                var offset: u32 = 0;
                while (scalar_it.nextCodepointSlice()) |slice| {
                    const inserted = try state.insertAt(
                        .prepare,
                        ins.index + @as(usize, offset),
                        .{ .op = event_change.id, .offset = offset },
                        .fromBytes(slice),
                    );
                    try metadata.inserted.append(metadata_allocator, inserted);
                    offset += 1;
                }
            },
            .delete => |del| {
                const visible_count = state.visibleCount(.prepare);
                if (del.index > visible_count or del.length > visible_count - del.index) {
                    return error.InvalidOperation;
                }

                var remaining = del.length;
                while (remaining > 0) : (remaining -= 1) {
                    const target = state.visibleAt(.prepare, del.index) orelse return error.InvalidOperation;
                    try state.advancePrepareDelete(target);
                    try state.deleteEffect(target);
                    try metadata.deleted.append(metadata_allocator, target);
                }
            },
        }
    }

    fn retreatEvent(state: *MergeIndex, metadata: *const EventMetadata) !void {
        for (metadata.inserted.items) |inserted| {
            try state.retreatPrepareInsert(inserted.id);
        }
        for (metadata.deleted.items) |target| {
            try state.retreatPrepareDelete(target);
        }
    }

    fn advanceEvent(state: *MergeIndex, metadata: *const EventMetadata) !void {
        for (metadata.inserted.items) |inserted| {
            try state.advancePrepareInsert(inserted.id);
        }
        for (metadata.deleted.items) |target| {
            try state.advancePrepareDelete(target);
        }
    }

    // Slow, exhaustive replay retained as a differential oracle while the
    // incremental walker is developed.  This intentionally uses the
    // independent reference model rather than MergeIndex itself, so a shared
    // ordering bug cannot make both sides of the comparison agree.
    fn rebuildOracle(self: *Replica) !void {
        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch = scratch_arena.allocator();

        const order = try self.topologicalOrder(scratch);
        defer scratch.free(order);

        const history_events = try scratch.alloc(fugue_oracle.HistoryEvent, self.events.items.len);
        for (self.events.items, history_events) |event, *history_event| {
            history_event.* = .{
                .id = event.change.id,
                .parents = event.change.parents.items,
                .operation = switch (event.change.operation) {
                    .insert => |insert_operation| .{ .insert = .{ .index = insert_operation.index, .text = insert_operation.text } },
                    .delete => |delete_operation| .{ .delete = .{ .index = delete_operation.index, .length = delete_operation.length } },
                },
            };
        }

        var rebuilt = try fugue_oracle.HistoryOracle.init(scratch, history_events, order);
        defer rebuilt.deinit();
        const rendered = try rebuilt.render(self.allocator);
        var new_visible: std.ArrayList(u8) = .empty;
        new_visible.items = rendered;
        new_visible.capacity = rendered.len;
        self.visible.deinit(self.allocator);
        self.visible = new_visible;
    }

    fn topologicalOrder(self: *const Replica, allocator: std.mem.Allocator) ![]usize {
        const order = try allocator.alloc(usize, self.events.items.len);
        errdefer allocator.free(order);

        const done = try allocator.alloc(bool, self.events.items.len);
        defer allocator.free(done);
        @memset(done, false);

        var count: usize = 0;
        while (count < self.events.items.len) {
            var selected: ?usize = null;
            for (self.events.items, 0..) |event, i| {
                if (done[i]) continue;

                var ready = true;
                for (event.change.parents.items) |parent| {
                    const parent_index = self.findEvent(parent) orelse return error.MissingParent;
                    if (!done[parent_index]) {
                        ready = false;
                        break;
                    }
                }
                if (!ready) continue;

                if (selected == null or self.events.items[i].change.id.order(self.events.items[selected.?].change.id) == .lt) {
                    selected = i;
                }
            }

            const index = selected orelse return error.CausalCycle;
            done[index] = true;
            order[count] = index;
            count += 1;
        }
        return order;
    }

    fn deriveMetadata(
        self: *Replica,
        event_index: usize,
        order: []const usize,
        metadata: []EventMetadata,
        scratch_allocator: std.mem.Allocator,
        metadata_allocator: std.mem.Allocator,
    ) !void {
        const parent_state = try self.stateForParents(
            self.events.items[event_index].change.parents.items,
            order,
            metadata,
            scratch_allocator,
        );
        defer parent_state.deinit();

        const event = &self.events.items[event_index];
        const event_metadata = &metadata[event_index];
        switch (event.change.operation) {
            .insert => |ins| {
                if (ins.index > parent_state.visibleCount(.effect)) return error.InvalidOperation;

                var scalar_it = (try std.unicode.Utf8View.init(ins.text)).iterator();
                var offset: u32 = 0;
                while (scalar_it.nextCodepointSlice()) |slice| {
                    const inserted = try parent_state.insertAt(
                        .effect,
                        ins.index + @as(usize, offset),
                        .{ .op = event.change.id, .offset = offset },
                        .fromBytes(slice),
                    );
                    try event_metadata.inserted.append(metadata_allocator, inserted);
                    offset += 1;
                }
            },
            .delete => |del| {
                const visible_count = parent_state.visibleCount(.effect);
                if (del.index > visible_count or del.length > visible_count - del.index) {
                    return error.InvalidOperation;
                }
                var remaining = del.length;
                var seen: usize = 0;
                for (parent_state.items()) |element| {
                    if (!element.effectVisible()) continue;
                    if (seen >= del.index and remaining > 0) {
                        try event_metadata.deleted.append(metadata_allocator, element.id);
                        remaining -= 1;
                    }
                    seen += 1;
                }
            },
        }
    }

    fn stateForParents(
        self: *Replica,
        parents: []const OpId,
        order: []const usize,
        metadata: []const EventMetadata,
        scratch_allocator: std.mem.Allocator,
    ) !*MergeIndex {
        const included = try scratch_allocator.alloc(bool, self.events.items.len);
        defer scratch_allocator.free(included);
        @memset(included, false);

        var stack: std.ArrayList(usize) = .empty;
        defer stack.deinit(scratch_allocator);
        for (parents) |parent| {
            const parent_index = self.findEvent(parent) orelse return error.MissingParent;
            try stack.append(scratch_allocator, parent_index);
        }
        while (stack.pop()) |event_index| {
            if (included[event_index]) continue;
            included[event_index] = true;
            for (self.events.items[event_index].change.parents.items) |parent| {
                const parent_index = self.findEvent(parent) orelse return error.MissingParent;
                try stack.append(scratch_allocator, parent_index);
            }
        }

        var state = try MergeIndex.initWithOrdering(scratch_allocator, self.ordering);
        errdefer state.deinit();
        for (order) |event_index| {
            if (included[event_index]) try self.applyEvent(state, &metadata[event_index]);
        }
        return state;
    }

    fn applyEvent(_: *Replica, state: *MergeIndex, metadata: *const EventMetadata) !void {
        for (metadata.inserted.items) |inserted| {
            try state.insert(inserted);
        }
        for (metadata.deleted.items) |target| {
            try state.deleteEffect(target);
        }
    }
};

fn containsOp(items: []const OpId, wanted: OpId) bool {
    for (items) |item| {
        if (item.eql(wanted)) return true;
    }
    return false;
}

fn frontiersEqual(left: []const OpId, right: []const OpId) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_id, right_id| {
        if (!left_id.eql(right_id)) return false;
    }
    return true;
}

fn scalarByteOffset(bytes: []const u8, scalar_index: usize) !usize {
    const view = std.unicode.Utf8View.init(bytes) catch return error.InvalidUtf8;
    var iterator = view.iterator();
    var current: usize = 0;
    while (current < scalar_index) : (current += 1) {
        if (iterator.nextCodepointSlice() == null) return error.IndexOutOfBounds;
    }
    return iterator.i;
}

fn validateChange(change: *const Change) !void {
    for (change.parents.items, 0..) |parent, i| {
        if (parent.eql(change.id)) return error.CausalCycle;
        if (i > 0 and change.parents.items[i - 1].order(parent) != .lt) {
            return error.InvalidParents;
        }
    }

    switch (change.operation) {
        .insert => |ins| {
            _ = std.unicode.utf8CountCodepoints(ins.text) catch return error.InvalidUtf8;
        },
        .delete => {},
    }
}

fn changesEqual(left: *const Change, right: *const Change) bool {
    if (!left.id.eql(right.id)) return false;
    if (left.parents.items.len != right.parents.items.len) return false;
    for (left.parents.items, right.parents.items) |a, b| {
        if (!a.eql(b)) return false;
    }
    return switch (left.operation) {
        .insert => |a| switch (right.operation) {
            .insert => |b| a.index == b.index and std.mem.eql(u8, a.text, b.text),
            .delete => false,
        },
        .delete => |a| switch (right.operation) {
            .insert => false,
            .delete => |b| a.index == b.index and a.length == b.length,
        },
    };
}

fn lessOpId(_: void, left: OpId, right: OpId) bool {
    return left.order(right) == .lt;
}

fn lessUsize(_: void, left: usize, right: usize) bool {
    return left < right;
}

fn lessPendingIndex(replica: *const Replica, left: usize, right: usize) bool {
    return replica.pending.items[left].id.order(replica.pending.items[right].id) == .lt;
}

fn appendU64(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .little);
    try list.appendSlice(allocator, &encoded);
}

fn appendU32(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, value, .little);
    try list.appendSlice(allocator, &encoded);
}

fn encodeChange(list: *std.ArrayList(u8), allocator: std.mem.Allocator, change: *const Change) !void {
    try appendOpId(list, allocator, change.id);
    try appendVarint(list, allocator, change.parents.items.len);
    for (change.parents.items) |parent| try appendOpId(list, allocator, parent);

    switch (change.operation) {
        .insert => |ins| {
            try list.append(allocator, 0);
            try appendVarint(list, allocator, ins.index);
            try appendVarint(list, allocator, ins.text.len);
            try list.appendSlice(allocator, ins.text);
        },
        .delete => |del| {
            try list.append(allocator, 1);
            try appendVarint(list, allocator, del.index);
            try appendVarint(list, allocator, del.length);
        },
    }
}

fn encodeLogFrame(list: *std.ArrayList(u8), allocator: std.mem.Allocator, change: *const Change) !void {
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(allocator);
    try encodeChange(&frame, allocator, change);
    try appendVarint(list, allocator, frame.items.len);
    try list.appendSlice(allocator, frame.items);
    try appendU32(list, allocator, std.hash.crc.Crc32.hash(frame.items));
}

fn decodeChange(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    cursor: *usize,
    options: LoadOptions,
) !Change {
    const change_id = try readOpId(bytes, cursor);
    const parent_count = try readVarint(bytes, cursor);
    if (parent_count > options.max_parents_per_change) return error.TooManyParents;
    var parents: std.ArrayList(OpId) = .empty;
    defer parents.deinit(allocator);
    try parents.ensureTotalCapacity(allocator, parent_count);
    var parent_index: usize = 0;
    while (parent_index < parent_count) : (parent_index += 1) {
        try parents.append(allocator, try readOpId(bytes, cursor));
    }

    var source_operation: Operation = undefined;
    switch (try readByte(bytes, cursor)) {
        0 => {
            const index = try readVarint(bytes, cursor);
            const text_len = try readVarint(bytes, cursor);
            if (text_len > options.max_insert_bytes) return error.InsertTooLarge;
            const text_bytes = try readBytes(bytes, cursor, text_len);
            source_operation = try Operation.initInsert(allocator, index, text_bytes);
        },
        1 => {
            const index = try readVarint(bytes, cursor);
            const length = try readVarint(bytes, cursor);
            source_operation = Operation.initDelete(index, length);
        },
        else => return error.InvalidFormat,
    }
    defer source_operation.deinit(allocator);
    return Change.init(allocator, change_id, parents.items, source_operation);
}

fn appendVarint(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: usize) !void {
    var remaining: u64 = @intCast(value);
    while (remaining >= 0x80) {
        try list.append(allocator, @as(u8, @intCast(remaining & 0x7f)) | 0x80);
        remaining >>= 7;
    }
    try list.append(allocator, @intCast(remaining));
}

fn appendOpId(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: OpId) !void {
    try list.appendSlice(allocator, &value.actor);
    try appendU64(list, allocator, value.counter);
}

fn readByte(bytes: []const u8, cursor: *usize) !u8 {
    if (cursor.* >= bytes.len) return error.UnexpectedEnd;
    const result = bytes[cursor.*];
    cursor.* += 1;
    return result;
}

fn readBytes(bytes: []const u8, cursor: *usize, length: usize) ![]const u8 {
    if (cursor.* > bytes.len or length > bytes.len - cursor.*) return error.UnexpectedEnd;
    const result = bytes[cursor.* .. cursor.* + length];
    cursor.* += length;
    return result;
}

fn readU64(bytes: []const u8, cursor: *usize) !u64 {
    const encoded = try readBytes(bytes, cursor, 8);
    return std.mem.readInt(u64, encoded[0..8], .little);
}

fn readU32(bytes: []const u8, cursor: *usize) !u32 {
    const encoded = try readBytes(bytes, cursor, 4);
    return std.mem.readInt(u32, encoded[0..4], .little);
}

fn readVarint(bytes: []const u8, cursor: *usize) !usize {
    var result: u64 = 0;
    var shift: u7 = 0;
    while (true) {
        const byte = try readByte(bytes, cursor);
        if (shift >= 64) return error.InvalidFormat;
        const payload = byte & 0x7f;
        if (shift == 63 and payload > 1) return error.InvalidFormat;
        result |= @as(u64, payload) << @intCast(shift);
        if ((byte & 0x80) == 0) {
            if (result > std.math.maxInt(usize)) return error.InvalidFormat;
            return @intCast(result);
        }
        if (shift >= 63) return error.InvalidFormat;
        shift += 7;
    }
}

fn readOpId(bytes: []const u8, cursor: *usize) !OpId {
    var actor: ActorId = undefined;
    const actor_bytes = try readBytes(bytes, cursor, actor.len);
    @memcpy(&actor, actor_bytes);
    return .{ .actor = actor, .counter = try readU64(bytes, cursor) };
}

fn deinitBatch(batch: *std.ArrayList(Change), allocator: std.mem.Allocator) void {
    for (batch.items) |change| change.deinit(allocator);
    batch.deinit(allocator);
}

fn deliverBatch(replica: *Replica, batch: *const std.ArrayList(Change), reverse: bool) !void {
    if (reverse) {
        var i = batch.items.len;
        while (i > 0) {
            i -= 1;
            _ = try replica.receive(&batch.items[i]);
        }
    } else {
        for (batch.items) |*change| _ = try replica.receive(change);
    }
}

test "replica stats expose identity and sizes without changing state" {
    const actor = [_]u8{0} ** 15 ++ [_]u8{7};
    var replica = try Replica.init(std.testing.allocator, actor);
    defer replica.deinit();

    const empty = replica.stats();
    try std.testing.expectEqual(actor, empty.actor);
    try std.testing.expectEqual(Ordering.fugue_max, empty.ordering);
    try std.testing.expectEqual(@as(u64, 0), empty.next_counter);
    try std.testing.expectEqual(@as(usize, 0), empty.history_events);
    try std.testing.expectEqual(@as(usize, 0), empty.pending_events);
    try std.testing.expectEqual(@as(usize, 0), empty.frontier_heads);
    try std.testing.expectEqual(@as(usize, 0), empty.text_bytes);
    try std.testing.expectEqual(@as(usize, 0), empty.text_scalars);

    const inserted_id = try replica.insert(0, "aé");
    const after = replica.stats();
    try std.testing.expectEqual(actor, replica.actorId());
    try std.testing.expectEqual(Ordering.fugue_max, replica.orderingMode());
    try std.testing.expect(replica.hasChange(inserted_id));
    try std.testing.expectEqual(@as(u64, 1), after.next_counter);
    try std.testing.expectEqual(@as(usize, 1), after.history_events);
    try std.testing.expectEqual(@as(usize, 1), after.frontier_heads);
    try std.testing.expectEqual(@as(usize, 3), after.text_bytes);
    try std.testing.expectEqual(@as(usize, 2), after.text_scalars);
}

test "applyGroup commits sequential edits atomically and returns ordinary changes" {
    const actor_a = [_]u8{0} ** 15 ++ [_]u8{8};
    const actor_b = [_]u8{0} ** 15 ++ [_]u8{9};
    var source = try Replica.init(std.testing.allocator, actor_a);
    defer source.deinit();
    var target = try Replica.init(std.testing.allocator, actor_b);
    defer target.deinit();

    const edits = [_]Edit{
        .{ .insert = .{ .index = 0, .text = "abc" } },
        .{ .insert = .{ .index = 1, .text = "é" } },
        .{ .delete = .{ .index = 2, .length = 1 } },
    };
    var group = try source.applyGroup(&edits, std.testing.allocator);
    defer group.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), group.len());
    try std.testing.expectEqualStrings("aéc", source.textView());
    try std.testing.expectEqual(@as(usize, 3), source.historyCount());

    var i = group.changes.items.len;
    while (i > 0) {
        i -= 1;
        _ = try target.receive(&group.changes.items[i]);
    }
    try std.testing.expectEqualStrings(source.textView(), target.textView());
    try std.testing.expectEqual(@as(usize, 3), target.historyCount());
}

test "applyGroup failure leaves the replica unchanged" {
    const actor = [_]u8{0} ** 15 ++ [_]u8{10};
    var replica = try Replica.init(std.testing.allocator, actor);
    defer replica.deinit();

    _ = try replica.insert(0, "abc");
    const before = replica.stats();
    const edits = [_]Edit{
        .{ .insert = .{ .index = 1, .text = "X" } },
        .{ .delete = .{ .index = 99, .length = 1 } },
    };
    try std.testing.expectError(error.IndexOutOfBounds, replica.applyGroup(&edits, std.testing.allocator));
    const after = replica.stats();

    try std.testing.expectEqual(before.next_counter, after.next_counter);
    try std.testing.expectEqual(before.history_events, after.history_events);
    try std.testing.expectEqual(before.frontier_heads, after.frontier_heads);
    try std.testing.expectEqualStrings("abc", replica.textView());
}

test "replicas converge for concurrent inserts and retain runs" {
    const a = [_]u8{0} ** 15 ++ [_]u8{1};
    const b = [_]u8{0} ** 15 ++ [_]u8{2};
    var first = try Replica.init(std.testing.allocator, a);
    defer first.deinit();
    var second = try Replica.init(std.testing.allocator, b);
    defer second.deinit();

    const a_id = try first.insert(0, "abc");
    const b_id = try second.insert(0, "XYZ");
    var a_change = try first.change(a_id, std.testing.allocator);
    defer a_change.deinit(std.testing.allocator);
    var b_change = try second.change(b_id, std.testing.allocator);
    defer b_change.deinit(std.testing.allocator);

    _ = try first.receive(&b_change);
    _ = try second.receive(&a_change);

    const first_text = try first.text(std.testing.allocator);
    defer std.testing.allocator.free(first_text);
    const second_text = try second.text(std.testing.allocator);
    defer std.testing.allocator.free(second_text);
    try std.testing.expectEqualStrings(first_text, second_text);
    try std.testing.expectEqualStrings("abcXYZ", first_text);
}

test "out of order receive is pending then applied" {
    const a = [_]u8{0} ** 15 ++ [_]u8{1};
    const b = [_]u8{0} ** 15 ++ [_]u8{2};
    var source = try Replica.init(std.testing.allocator, a);
    defer source.deinit();
    var target = try Replica.init(std.testing.allocator, b);
    defer target.deinit();

    const parent_id = try source.insert(0, "A");
    const child_id = try source.insert(1, "B");
    var parent = try source.change(parent_id, std.testing.allocator);
    defer parent.deinit(std.testing.allocator);
    var child = try source.change(child_id, std.testing.allocator);
    defer child.deinit(std.testing.allocator);

    try std.testing.expectEqual(ReceiveResult.pending, try target.receive(&child));
    try std.testing.expectEqual(ReceiveResult.applied, try target.receive(&parent));

    const rendered = try target.text(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("AB", rendered);
}

test "duplicate pending delivery does not add a second queued change" {
    const source_actor = [_]u8{0} ** 15 ++ [_]u8{4};
    const target_actor = [_]u8{0} ** 15 ++ [_]u8{5};
    var source = try Replica.init(std.testing.allocator, source_actor);
    defer source.deinit();
    var target = try Replica.init(std.testing.allocator, target_actor);
    defer target.deinit();

    _ = try source.insert(0, "A");
    const child_id = try source.insert(1, "B");
    var child = try source.change(child_id, std.testing.allocator);
    defer child.deinit(std.testing.allocator);

    try std.testing.expectEqual(ReceiveResult.pending, try target.receive(&child));
    try std.testing.expectEqual(ReceiveResult.pending, try target.receive(&child));
    try std.testing.expectEqual(@as(usize, 1), target.pendingCount());
}

test "changesSince returns only events outside a known causal version" {
    const actor = [_]u8{0} ** 15 ++ [_]u8{1};
    var replica = try Replica.init(std.testing.allocator, actor);
    defer replica.deinit();

    const first_id = try replica.insert(0, "A");
    var known = try replica.version(std.testing.allocator);
    defer known.deinit(std.testing.allocator);
    const second_id = try replica.insert(1, "B");

    var missing = try replica.changesSince(&known, std.testing.allocator);
    defer {
        for (missing.items) |event| event.deinit(std.testing.allocator);
        missing.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), missing.items.len);
    try std.testing.expect(OpId.eql(second_id, missing.items[0].id));
    try std.testing.expect(!OpId.eql(first_id, missing.items[0].id));
}

test "changesSince emits a deterministic causal order independent of arrival order" {
    const actor_a = [_]u8{0} ** 15 ++ [_]u8{1};
    const actor_b = [_]u8{0} ** 15 ++ [_]u8{2};
    const receiver_actor = [_]u8{0} ** 15 ++ [_]u8{3};

    var source_a = try Replica.init(std.testing.allocator, actor_a);
    defer source_a.deinit();
    var source_b = try Replica.init(std.testing.allocator, actor_b);
    defer source_b.deinit();
    var first = try Replica.init(std.testing.allocator, receiver_actor);
    defer first.deinit();
    var second = try Replica.init(std.testing.allocator, receiver_actor);
    defer second.deinit();

    const a_id = try source_a.insert(0, "A");
    const b_id = try source_b.insert(0, "B");
    var a_change = try source_a.change(a_id, std.testing.allocator);
    defer a_change.deinit(std.testing.allocator);
    var b_change = try source_b.change(b_id, std.testing.allocator);
    defer b_change.deinit(std.testing.allocator);

    _ = try first.receive(&a_change);
    _ = try first.receive(&b_change);
    _ = try second.receive(&b_change);
    _ = try second.receive(&a_change);

    var empty_first = Version{};
    var first_batch = try first.changesSince(&empty_first, std.testing.allocator);
    defer deinitBatch(&first_batch, std.testing.allocator);
    var empty_second = Version{};
    var second_batch = try second.changesSince(&empty_second, std.testing.allocator);
    defer deinitBatch(&second_batch, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), first_batch.items.len);
    try std.testing.expectEqual(first_batch.items.len, second_batch.items.len);
    for (first_batch.items, second_batch.items) |left, right| {
        try std.testing.expect(OpId.eql(left.id, right.id));
    }
    try std.testing.expect(OpId.eql(a_id, first_batch.items[0].id));
    try std.testing.expect(OpId.eql(b_id, first_batch.items[1].id));
}

test "version diff identifies the branches needed for a walker" {
    const actor_a = [_]u8{0} ** 15 ++ [_]u8{1};
    const actor_b = [_]u8{0} ** 15 ++ [_]u8{2};
    var first = try Replica.init(std.testing.allocator, actor_a);
    defer first.deinit();
    var second = try Replica.init(std.testing.allocator, actor_b);
    defer second.deinit();

    const root_id = try first.insert(0, "A");
    var root = try first.change(root_id, std.testing.allocator);
    defer root.deinit(std.testing.allocator);
    _ = try second.receive(&root);

    var base = try first.version(std.testing.allocator);
    defer base.deinit(std.testing.allocator);
    const first_branch = try first.insert(1, "a");
    const second_branch = try second.insert(1, "b");
    var first_change = try first.change(first_branch, std.testing.allocator);
    defer first_change.deinit(std.testing.allocator);
    var second_change = try second.change(second_branch, std.testing.allocator);
    defer second_change.deinit(std.testing.allocator);
    _ = try first.receive(&second_change);
    _ = try second.receive(&first_change);

    var merged = try first.version(std.testing.allocator);
    defer merged.deinit(std.testing.allocator);
    var difference = try first.diff(&base, &merged, std.testing.allocator);
    defer difference.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), difference.only_from.items.len);
    try std.testing.expectEqual(@as(usize, 2), difference.only_to.items.len);
    try std.testing.expect(OpId.eql(first_branch, difference.only_to.items[0]));
    try std.testing.expect(OpId.eql(second_branch, difference.only_to.items[1]));
}

test "save and load preserve the document and causal history" {
    const actor = [_]u8{0} ** 15 ++ [_]u8{1};
    var original = try Replica.init(std.testing.allocator, actor);
    defer original.deinit();

    _ = try original.insert(0, "hello");
    _ = try original.delete(1, 2);

    const encoded = try original.save(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    var restored = try Replica.load(std.testing.allocator, encoded);
    defer restored.deinit();

    const original_text = try original.text(std.testing.allocator);
    defer std.testing.allocator.free(original_text);
    const restored_text = try restored.text(std.testing.allocator);
    defer std.testing.allocator.free(restored_text);
    try std.testing.expectEqualStrings("hlo", original_text);
    try std.testing.expectEqualStrings(original_text, restored_text);
    try std.testing.expectEqual(original.frontier.items.len, restored.frontier.items.len);
}

test "save and load preserve the selected sequence ordering" {
    const actor = [_]u8{0} ** 15 ++ [_]u8{101};
    var original = try Replica.initWithOrdering(std.testing.allocator, actor, .fugue);
    defer original.deinit();
    _ = try original.insert(0, "compat");

    const encoded = try original.save(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    var restored = try Replica.load(std.testing.allocator, encoded);
    defer restored.deinit();

    try std.testing.expectEqual(Ordering.fugue, restored.ordering);
    try std.testing.expectEqualStrings(original.textView(), restored.textView());
}

test "save and load preserve pending out of order changes" {
    const source_actor = [_]u8{0} ** 15 ++ [_]u8{1};
    const target_actor = [_]u8{0} ** 15 ++ [_]u8{2};
    var source = try Replica.init(std.testing.allocator, source_actor);
    defer source.deinit();
    var target = try Replica.init(std.testing.allocator, target_actor);
    defer target.deinit();

    const parent_id = try source.insert(0, "A");
    const child_id = try source.insert(1, "B");
    var child = try source.change(child_id, std.testing.allocator);
    defer child.deinit(std.testing.allocator);
    try std.testing.expectEqual(ReceiveResult.pending, try target.receive(&child));

    const encoded = try target.save(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    var restored = try Replica.load(std.testing.allocator, encoded);
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 1), restored.pending.items.len);
    try std.testing.expectEqual(@as(usize, 0), restored.events.items.len);

    var parent = try source.change(parent_id, std.testing.allocator);
    defer parent.deinit(std.testing.allocator);
    try std.testing.expectEqual(ReceiveResult.applied, try restored.receive(&parent));
    const rendered = try restored.text(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("AB", rendered);
}

test "filesystem snapshot round trip is restart-safe" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const actor = [_]u8{0} ** 15 ++ [_]u8{89};
    var original = try Replica.initWithOrdering(std.testing.allocator, actor, .fugue);
    defer original.deinit();
    _ = try original.insert(0, "ab");

    const encoded = try original.save(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try tmp.dir.writeFile(io, .{
        .sub_path = "snapshot.bin",
        .data = encoded,
    });

    const on_disk = try tmp.dir.readFileAlloc(
        io,
        "snapshot.bin",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(on_disk);

    var restored = try Replica.load(std.testing.allocator, on_disk);
    defer restored.deinit();
    try std.testing.expectEqual(Ordering.fugue, restored.ordering);
    try std.testing.expectEqualStrings("ab", restored.textView());

    // A process restart must not reuse an operation ID that is already in
    // the persisted history.
    const next_id = try restored.insert(2, "c");
    try std.testing.expectEqual(@as(u64, 1), next_id.counter);
    try std.testing.expectEqualStrings("abc", restored.textView());
}

test "load bounds reject an excessive accepted-event count" {
    const actor = [_]u8{0} ** 15 ++ [_]u8{81};
    var replica = try Replica.init(std.testing.allocator, actor);
    defer replica.deinit();
    _ = try replica.insert(0, "event");

    const encoded = try replica.save(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectError(
        error.TooManyEvents,
        Replica.loadWithOptions(std.testing.allocator, encoded, .{ .max_events = 0 }),
    );
}

test "load bounds reject oversized frames and insertion payloads" {
    const actor = [_]u8{0} ** 15 ++ [_]u8{82};
    var replica = try Replica.init(std.testing.allocator, actor);
    defer replica.deinit();
    _ = try replica.insert(0, "hello");

    const encoded = try replica.save(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectError(
        error.FrameTooLarge,
        Replica.loadWithOptions(std.testing.allocator, encoded, .{ .max_frame_bytes = 1 }),
    );
    try std.testing.expectError(
        error.InsertTooLarge,
        Replica.loadWithOptions(std.testing.allocator, encoded, .{ .max_insert_bytes = 2 }),
    );
}

test "load bounds reject an excessive parent frontier" {
    const actor_a = [_]u8{0} ** 15 ++ [_]u8{83};
    const actor_b = [_]u8{0} ** 15 ++ [_]u8{84};
    const actor_c = [_]u8{0} ** 15 ++ [_]u8{85};
    var first = try Replica.init(std.testing.allocator, actor_a);
    defer first.deinit();
    var second = try Replica.init(std.testing.allocator, actor_b);
    defer second.deinit();
    var merged = try Replica.init(std.testing.allocator, actor_c);
    defer merged.deinit();

    const first_id = try first.insert(0, "A");
    const second_id = try second.insert(0, "B");
    var first_change = try first.change(first_id, std.testing.allocator);
    defer first_change.deinit(std.testing.allocator);
    var second_change = try second.change(second_id, std.testing.allocator);
    defer second_change.deinit(std.testing.allocator);
    _ = try merged.receive(&first_change);
    _ = try merged.receive(&second_change);
    _ = try merged.insert(0, "X");

    const encoded = try merged.save(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectError(
        error.TooManyParents,
        Replica.loadWithOptions(std.testing.allocator, encoded, .{ .max_parents_per_change = 1 }),
    );
}

test "load bounds reject an excessive pending-change count" {
    const source_actor = [_]u8{0} ** 15 ++ [_]u8{86};
    const target_actor = [_]u8{0} ** 15 ++ [_]u8{87};
    var source = try Replica.init(std.testing.allocator, source_actor);
    defer source.deinit();
    var target = try Replica.init(std.testing.allocator, target_actor);
    defer target.deinit();

    const parent_id = try source.insert(0, "A");
    _ = try source.insert(1, "B");
    const child_id = OpId{ .actor = source_actor, .counter = 1 };
    var child = try source.change(child_id, std.testing.allocator);
    defer child.deinit(std.testing.allocator);
    try std.testing.expectEqual(ReceiveResult.pending, try target.receive(&child));

    const encoded = try target.save(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectError(
        error.TooManyPending,
        Replica.loadWithOptions(std.testing.allocator, encoded, .{ .max_pending = 0 }),
    );

    // Keep the parent ID live in this test's source graph so the child above
    // remains an explicitly out-of-order change rather than an arbitrary ID.
    try std.testing.expect(parent_id.counter == 0);
}

test "load rejects a frame mislabeled as pending" {
    const actor = [_]u8{0} ** 15 ++ [_]u8{87};
    var source = try Replica.init(std.testing.allocator, actor);
    defer source.deinit();
    _ = try source.insert(0, "accepted");

    const encoded = try source.save(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    // The snapshot header stores one-byte varints for these counts in this
    // fixture: move the accepted frame from the event section to the pending
    // section without changing its payload.
    var mislabeled = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(mislabeled);
    try std.testing.expectEqual(@as(u8, 1), mislabeled[34]);
    try std.testing.expectEqual(@as(u8, 0), mislabeled[35]);
    mislabeled[34] = 0;
    mislabeled[35] = 1;
    try std.testing.expectError(error.InvalidFormat, Replica.load(std.testing.allocator, mislabeled));
}

test "counter exhaustion rejects local edits without changing state" {
    const actor = [_]u8{0} ** 15 ++ [_]u8{120};
    var replica = try Replica.init(std.testing.allocator, actor);
    defer replica.deinit();
    replica.next_counter = std.math.maxInt(u64);

    try std.testing.expectError(error.CounterExhausted, replica.insert(0, "x"));
    try std.testing.expectError(error.CounterExhausted, replica.delete(0, 0));
    try std.testing.expectEqual(@as(usize, 0), replica.historyCount());
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), replica.next_counter);
    try std.testing.expectEqualStrings("", replica.textView());
}

test "local scalar operations accept the end boundary and zero-length delete" {
    const actor = [_]u8{0} ** 15 ++ [_]u8{121};
    var replica = try Replica.init(std.testing.allocator, actor);
    defer replica.deinit();

    _ = try replica.insert(0, "ab");
    _ = try replica.insert(2, "");
    _ = try replica.delete(2, 0);
    try std.testing.expectEqual(@as(usize, 3), replica.historyCount());
    try std.testing.expectEqual(@as(usize, 1), replica.frontierView().len);
    try std.testing.expectEqual(@as(u64, 2), replica.frontierView()[0].counter);
    try std.testing.expectEqualStrings("ab", replica.textView());
}

test "local scalar operations reject positions past the end" {
    const actor = [_]u8{0} ** 15 ++ [_]u8{122};
    var replica = try Replica.init(std.testing.allocator, actor);
    defer replica.deinit();
    _ = try replica.insert(0, "ab");

    try std.testing.expectError(error.IndexOutOfBounds, replica.insert(3, "x"));
    try std.testing.expectError(error.IndexOutOfBounds, replica.delete(3, 0));
    try std.testing.expectError(error.IndexOutOfBounds, replica.delete(1, 2 + 1));
    try std.testing.expectEqual(@as(usize, 1), replica.historyCount());
    try std.testing.expectEqual(@as(u64, 0), replica.frontierView()[0].counter);
    try std.testing.expectEqualStrings("ab", replica.textView());
}

test "load bounds reject an input byte limit before constructing a replica" {
    const actor = [_]u8{0} ** 15 ++ [_]u8{88};
    var replica = try Replica.init(std.testing.allocator, actor);
    defer replica.deinit();
    _ = try replica.insert(0, "bytes");

    const encoded = try replica.save(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(encoded.len > 0);
    try std.testing.expectError(
        error.InputTooLarge,
        Replica.loadWithOptions(std.testing.allocator, encoded, .{ .max_input_bytes = encoded.len - 1 }),
    );
}

test "ChangeLog appends changes and replays duplicate deliveries idempotently" {
    const source_actor = [_]u8{0} ** 15 ++ [_]u8{91};
    const target_actor = [_]u8{0} ** 15 ++ [_]u8{92};
    var source = try Replica.init(std.testing.allocator, source_actor);
    defer source.deinit();
    var target = try Replica.init(std.testing.allocator, target_actor);
    defer target.deinit();

    const first_id = try source.insert(0, "A");
    var first = try source.change(first_id, std.testing.allocator);
    defer first.deinit(std.testing.allocator);
    const second_id = try source.insert(1, "β");
    var second = try source.change(second_id, std.testing.allocator);
    defer second.deinit(std.testing.allocator);

    var log = ChangeLog.init(std.testing.allocator);
    defer log.deinit();
    try log.append(&first);
    try log.append(&second);
    try std.testing.expect(log.bytesView().len > 0);

    const replayed = try log.replay(target, .{});
    try std.testing.expectEqual(@as(usize, 2), replayed.frames);
    try std.testing.expectEqual(@as(usize, 2), replayed.applied);
    try std.testing.expectEqual(@as(usize, 0), replayed.duplicates);
    try std.testing.expectEqual(@as(usize, 0), replayed.pending);
    try std.testing.expect(!replayed.recovered_tail);
    try std.testing.expectEqual(log.bytesView().len, replayed.consumed_bytes);
    try std.testing.expectEqualStrings("Aβ", target.textView());

    const retry = try log.replay(target, .{});
    try std.testing.expectEqual(@as(usize, 2), retry.frames);
    try std.testing.expectEqual(@as(usize, 0), retry.applied);
    try std.testing.expectEqual(@as(usize, 2), retry.duplicates);
    try std.testing.expectEqual(@as(usize, 2), target.historyCount());
    try std.testing.expectEqualStrings("Aβ", target.textView());
}

test "ChangeLog can transfer its encoded bytes without retaining ownership" {
    const actor = [_]u8{0} ** 15 ++ [_]u8{90};
    var source = try Replica.init(std.testing.allocator, actor);
    defer source.deinit();
    const change_id = try source.insert(0, "owned");
    var change = try source.change(change_id, std.testing.allocator);
    defer change.deinit(std.testing.allocator);

    var log = ChangeLog.init(std.testing.allocator);
    try log.append(&change);
    const bytes = try log.toOwnedSlice();
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(bytes.len > 0);
    try std.testing.expectEqual(@as(usize, 0), log.bytesView().len);
    log.deinit();
}

test "ChangeLog replay repairs an out-of-order child and drains pending state" {
    const source_actor = [_]u8{0} ** 15 ++ [_]u8{93};
    const target_actor = [_]u8{0} ** 15 ++ [_]u8{94};
    var source = try Replica.init(std.testing.allocator, source_actor);
    defer source.deinit();
    var target = try Replica.init(std.testing.allocator, target_actor);
    defer target.deinit();

    const parent_id = try source.insert(0, "A");
    const child_id = try source.insert(1, "B");
    var parent = try source.change(parent_id, std.testing.allocator);
    defer parent.deinit(std.testing.allocator);
    var child = try source.change(child_id, std.testing.allocator);
    defer child.deinit(std.testing.allocator);

    var log = ChangeLog.init(std.testing.allocator);
    defer log.deinit();
    try log.append(&child);
    try log.append(&parent);

    const result = try log.replay(target, .{});
    try std.testing.expectEqual(@as(usize, 2), result.frames);
    try std.testing.expectEqual(@as(usize, 1), result.applied);
    try std.testing.expectEqual(@as(usize, 0), result.pending);
    try std.testing.expectEqual(@as(usize, 2), target.historyCount());
    try std.testing.expectEqualStrings("AB", target.textView());
}

test "ChangeLog appendSince emits only changes outside a known version" {
    const source_actor = [_]u8{0} ** 15 ++ [_]u8{95};
    const target_actor = [_]u8{0} ** 15 ++ [_]u8{96};
    var source = try Replica.init(std.testing.allocator, source_actor);
    defer source.deinit();
    var target = try Replica.init(std.testing.allocator, target_actor);
    defer target.deinit();

    const first_id = try source.insert(0, "A");
    var first = try source.change(first_id, std.testing.allocator);
    defer first.deinit(std.testing.allocator);
    _ = try target.receive(&first);
    var known = try source.version(std.testing.allocator);
    defer known.deinit(std.testing.allocator);

    const second_id = try source.insert(1, "B");
    var second = try source.change(second_id, std.testing.allocator);
    defer second.deinit(std.testing.allocator);

    var log = ChangeLog.init(std.testing.allocator);
    defer log.deinit();
    try log.appendSince(source, &known);
    const result = try log.replay(target, .{});
    try std.testing.expectEqual(@as(usize, 1), result.frames);
    try std.testing.expectEqual(@as(usize, 1), result.applied);
    try std.testing.expectEqualStrings("AB", target.textView());
}

test "ChangeLog strict replay rejects a torn tail without mutating the target" {
    const source_actor = [_]u8{0} ** 15 ++ [_]u8{97};
    const target_actor = [_]u8{0} ** 15 ++ [_]u8{98};
    var source = try Replica.init(std.testing.allocator, source_actor);
    defer source.deinit();
    var target = try Replica.init(std.testing.allocator, target_actor);
    defer target.deinit();

    const parent_id = try source.insert(0, "A");
    const child_id = try source.insert(1, "B");
    var parent = try source.change(parent_id, std.testing.allocator);
    defer parent.deinit(std.testing.allocator);
    var child = try source.change(child_id, std.testing.allocator);
    defer child.deinit(std.testing.allocator);
    var log = ChangeLog.init(std.testing.allocator);
    defer log.deinit();
    try log.append(&parent);
    try log.append(&child);

    const full = log.bytesView();
    const truncated = try std.testing.allocator.dupe(u8, full[0 .. full.len - 2]);
    defer std.testing.allocator.free(truncated);
    try std.testing.expectError(error.UnexpectedEnd, target.replayLog(truncated, .{}));
    try std.testing.expectEqual(@as(usize, 0), target.historyCount());
    try std.testing.expectEqualStrings("", target.textView());
}

test "ChangeLog recovery commits the complete prefix of a torn tail" {
    const source_actor = [_]u8{0} ** 15 ++ [_]u8{99};
    const target_actor = [_]u8{0} ** 15 ++ [_]u8{100};
    var source = try Replica.init(std.testing.allocator, source_actor);
    defer source.deinit();
    var target = try Replica.init(std.testing.allocator, target_actor);
    defer target.deinit();

    const parent_id = try source.insert(0, "A");
    const child_id = try source.insert(1, "B");
    var parent = try source.change(parent_id, std.testing.allocator);
    defer parent.deinit(std.testing.allocator);
    var child = try source.change(child_id, std.testing.allocator);
    defer child.deinit(std.testing.allocator);
    var log = ChangeLog.init(std.testing.allocator);
    defer log.deinit();
    try log.append(&parent);
    const prefix_len = log.bytesView().len;
    try log.append(&child);

    const full = log.bytesView();
    const truncated = try std.testing.allocator.dupe(u8, full[0 .. full.len - 2]);
    defer std.testing.allocator.free(truncated);
    const result = try target.replayLog(truncated, .{ .tail_policy = .recover });
    try std.testing.expectEqual(@as(usize, 1), result.frames);
    try std.testing.expectEqual(@as(usize, 1), result.applied);
    try std.testing.expectEqual(prefix_len, result.consumed_bytes);
    try std.testing.expect(result.recovered_tail);
    try std.testing.expectEqualStrings("A", target.textView());
}

test "ChangeLog recovery never accepts a complete frame with a bad checksum" {
    const source_actor = [_]u8{0} ** 15 ++ [_]u8{101};
    const target_actor = [_]u8{0} ** 15 ++ [_]u8{102};
    var source = try Replica.init(std.testing.allocator, source_actor);
    defer source.deinit();
    var target = try Replica.init(std.testing.allocator, target_actor);
    defer target.deinit();

    const change_id = try source.insert(0, "A");
    var change = try source.change(change_id, std.testing.allocator);
    defer change.deinit(std.testing.allocator);
    var log = ChangeLog.init(std.testing.allocator);
    defer log.deinit();
    try log.append(&change);

    var corrupted = try std.testing.allocator.dupe(u8, log.bytesView());
    defer std.testing.allocator.free(corrupted);
    corrupted[corrupted.len - 1] ^= 0x01;
    try std.testing.expectError(
        error.ChecksumMismatch,
        target.replayLog(corrupted, .{ .tail_policy = .recover }),
    );
    try std.testing.expectEqual(@as(usize, 0), target.historyCount());
    try std.testing.expectEqualStrings("", target.textView());
}

test "filesystem ChangeLog recovery keeps only the complete prefix" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source_actor = [_]u8{0} ** 15 ++ [_]u8{106};
    const target_actor = [_]u8{0} ** 15 ++ [_]u8{107};
    var source = try Replica.init(std.testing.allocator, source_actor);
    defer source.deinit();
    var target = try Replica.init(std.testing.allocator, target_actor);
    defer target.deinit();

    const parent_id = try source.insert(0, "A");
    const child_id = try source.insert(1, "B");
    var parent = try source.change(parent_id, std.testing.allocator);
    defer parent.deinit(std.testing.allocator);
    var child = try source.change(child_id, std.testing.allocator);
    defer child.deinit(std.testing.allocator);

    var log = ChangeLog.init(std.testing.allocator);
    defer log.deinit();
    try log.append(&parent);
    const prefix_len = log.bytesView().len;
    try log.append(&child);

    const full = log.bytesView();
    const torn = try std.testing.allocator.dupe(u8, full[0 .. full.len - 1]);
    defer std.testing.allocator.free(torn);
    try tmp.dir.writeFile(io, .{
        .sub_path = "changes.log",
        .data = torn,
    });

    const on_disk = try tmp.dir.readFileAlloc(
        io,
        "changes.log",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(on_disk);

    const result = try target.replayLog(on_disk, .{ .tail_policy = .recover });
    try std.testing.expectEqual(@as(usize, 1), result.frames);
    try std.testing.expectEqual(@as(usize, 1), result.applied);
    try std.testing.expectEqual(prefix_len, result.consumed_bytes);
    try std.testing.expect(result.recovered_tail);
    try std.testing.expectEqualStrings("A", target.textView());
}

test "ChangeLog replay is atomic when a complete frame contains an invalid edit" {
    const source_actor = [_]u8{0} ** 15 ++ [_]u8{103};
    const target_actor = [_]u8{0} ** 15 ++ [_]u8{104};
    var source = try Replica.init(std.testing.allocator, source_actor);
    defer source.deinit();
    var target = try Replica.init(std.testing.allocator, target_actor);
    defer target.deinit();

    const parent_id = try source.insert(0, "A");
    var parent = try source.change(parent_id, std.testing.allocator);
    defer parent.deinit(std.testing.allocator);
    const invalid_id = OpId{ .actor = [_]u8{0} ** 15 ++ [_]u8{105}, .counter = 0 };
    var invalid_operation = try Operation.initInsert(std.testing.allocator, 99, "X");
    defer invalid_operation.deinit(std.testing.allocator);
    var invalid = try Change.init(std.testing.allocator, invalid_id, &.{parent_id}, invalid_operation);
    defer invalid.deinit(std.testing.allocator);

    var log = ChangeLog.init(std.testing.allocator);
    defer log.deinit();
    try log.append(&parent);
    try log.append(&invalid);

    try std.testing.expectError(error.InvalidOperation, log.replay(target, .{}));
    try std.testing.expectEqual(@as(usize, 0), target.historyCount());
    try std.testing.expectEqualStrings("", target.textView());
}

test "persistence and replay limits fail before mutating a target" {
    const source_actor = [_]u8{0} ** 15 ++ [_]u8{108};
    const target_actor = [_]u8{0} ** 15 ++ [_]u8{109};
    var source = try Replica.init(std.testing.allocator, source_actor);
    defer source.deinit();
    var target = try Replica.init(std.testing.allocator, target_actor);
    defer target.deinit();

    const change_id = try source.insert(0, "bounded");
    var change = try source.change(change_id, std.testing.allocator);
    defer change.deinit(std.testing.allocator);

    var log = ChangeLog.init(std.testing.allocator);
    defer log.deinit();
    try log.append(&change);
    try std.testing.expect(log.bytesView().len > 1);

    try std.testing.expectError(
        error.InputTooLarge,
        log.replay(target, .{ .limits = .{ .max_input_bytes = log.bytesView().len - 1 } }),
    );
    try std.testing.expectEqual(@as(usize, 0), target.historyCount());
    try std.testing.expectError(
        error.FrameTooLarge,
        log.replay(target, .{ .limits = .{ .max_frame_bytes = 1 } }),
    );
    try std.testing.expectEqual(@as(usize, 0), target.historyCount());
    try std.testing.expectError(
        error.TooManyLogFrames,
        log.replay(target, .{ .limits = .{ .max_log_frames = 0 } }),
    );
    try std.testing.expectEqual(@as(usize, 0), target.historyCount());
}

test "a duplicate ID with different content is rejected" {
    const actor = [_]u8{0} ** 15 ++ [_]u8{1};
    const other_actor = [_]u8{0} ** 15 ++ [_]u8{2};
    var source = try Replica.init(std.testing.allocator, actor);
    defer source.deinit();
    var target = try Replica.init(std.testing.allocator, other_actor);
    defer target.deinit();

    const change_id = try source.insert(0, "A");
    var original = try source.change(change_id, std.testing.allocator);
    defer original.deinit(std.testing.allocator);
    _ = try target.receive(&original);

    var conflicting_operation = try Operation.initInsert(std.testing.allocator, 0, "B");
    defer conflicting_operation.deinit(std.testing.allocator);
    var conflicting = try Change.init(std.testing.allocator, change_id, &.{}, conflicting_operation);
    defer conflicting.deinit(std.testing.allocator);

    try std.testing.expectError(error.ConflictingDuplicate, target.receive(&conflicting));
}

test "receive rejects a non-canonical parent frontier before buffering it" {
    const actor = [_]u8{0} ** 15 ++ [_]u8{1};
    var replica = try Replica.init(std.testing.allocator, actor);
    defer replica.deinit();

    var operation = try Operation.initInsert(std.testing.allocator, 0, "x");
    defer operation.deinit(std.testing.allocator);
    const first_parent = OpId{ .actor = [_]u8{0} ** 15 ++ [_]u8{2}, .counter = 0 };
    const second_parent = OpId{ .actor = [_]u8{0} ** 15 ++ [_]u8{3}, .counter = 0 };
    var malformed = try Change.init(
        std.testing.allocator,
        OpId{ .actor = actor, .counter = 0 },
        &.{ first_parent, second_parent },
        operation,
    );
    defer malformed.deinit(std.testing.allocator);

    // Change.init canonicalizes parents. Mutating the owned value simulates a
    // caller handing receive a malformed decoded frame.
    const first = malformed.parents.items[0];
    malformed.parents.items[0] = malformed.parents.items[1];
    malformed.parents.items[1] = first;

    try std.testing.expectError(error.InvalidParents, replica.receive(&malformed));
    try std.testing.expectEqual(@as(usize, 0), replica.events.items.len);
    try std.testing.expectEqual(@as(usize, 0), replica.pending.items.len);
}

test "receive rejects a frontier that contains an ancestor and its descendant" {
    const source_actor = [_]u8{0} ** 15 ++ [_]u8{6};
    const target_actor = [_]u8{0} ** 15 ++ [_]u8{7};
    var source = try Replica.init(std.testing.allocator, source_actor);
    defer source.deinit();
    var target = try Replica.init(std.testing.allocator, target_actor);
    defer target.deinit();

    const first_id = try source.insert(0, "A");
    const second_id = try source.insert(1, "B");
    var first = try source.change(first_id, std.testing.allocator);
    defer first.deinit(std.testing.allocator);
    var second = try source.change(second_id, std.testing.allocator);
    defer second.deinit(std.testing.allocator);
    _ = try target.receive(&first);
    _ = try target.receive(&second);

    var operation = try Operation.initInsert(std.testing.allocator, 2, "x");
    defer operation.deinit(std.testing.allocator);
    var malformed = try Change.init(
        std.testing.allocator,
        .{ .actor = target_actor, .counter = 0 },
        &.{ first_id, second_id },
        operation,
    );
    defer malformed.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidParents, target.receive(&malformed));
    try std.testing.expectEqual(@as(usize, 2), target.historyCount());
    try std.testing.expectEqual(@as(usize, 0), target.pendingCount());
}

test "receive rejects a self-parent before buffering" {
    const actor = [_]u8{0} ** 15 ++ [_]u8{8};
    var replica = try Replica.init(std.testing.allocator, actor);
    defer replica.deinit();

    const self_id = OpId{ .actor = actor, .counter = 0 };
    var operation = try Operation.initInsert(std.testing.allocator, 0, "x");
    defer operation.deinit(std.testing.allocator);
    var malformed = try Change.init(std.testing.allocator, self_id, &.{self_id}, operation);
    defer malformed.deinit(std.testing.allocator);

    try std.testing.expectError(error.CausalCycle, replica.receive(&malformed));
    try std.testing.expectEqual(@as(usize, 0), replica.historyCount());
    try std.testing.expectEqual(@as(usize, 0), replica.pendingCount());
}

test "receive rejects invalid UTF-8 without changing history" {
    const actor = [_]u8{0} ** 15 ++ [_]u8{1};
    var replica = try Replica.init(std.testing.allocator, actor);
    defer replica.deinit();

    var operation = try Operation.initInsert(std.testing.allocator, 0, &[_]u8{0xff});
    defer operation.deinit(std.testing.allocator);
    var malformed = try Change.init(
        std.testing.allocator,
        OpId{ .actor = [_]u8{0} ** 15 ++ [_]u8{2}, .counter = 0 },
        &.{},
        operation,
    );
    defer malformed.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidUtf8, replica.receive(&malformed));
    try std.testing.expectEqual(@as(usize, 0), replica.events.items.len);
    try std.testing.expectEqual(@as(usize, 0), replica.pending.items.len);
}

test "receiving an actor's out of order changes advances its local counter" {
    const actor = [_]u8{0} ** 15 ++ [_]u8{1};
    var source = try Replica.init(std.testing.allocator, actor);
    defer source.deinit();
    var target = try Replica.init(std.testing.allocator, actor);
    defer target.deinit();

    const first_id = try source.insert(0, "A");
    const second_id = try source.insert(1, "B");
    var first = try source.change(first_id, std.testing.allocator);
    defer first.deinit(std.testing.allocator);
    var second = try source.change(second_id, std.testing.allocator);
    defer second.deinit(std.testing.allocator);

    try std.testing.expectEqual(ReceiveResult.pending, try target.receive(&second));
    try std.testing.expectEqual(ReceiveResult.applied, try target.receive(&first));
    try std.testing.expectEqual(@as(u64, 2), target.next_counter);

    const third_id = try target.insert(2, "C");
    try std.testing.expectEqual(@as(u64, 2), third_id.counter);
}

test "a rejected remote operation leaves the replay cache usable" {
    const source_actor = [_]u8{0} ** 15 ++ [_]u8{1};
    const bad_actor = [_]u8{0} ** 15 ++ [_]u8{2};
    const target_actor = [_]u8{0} ** 15 ++ [_]u8{3};
    var source = try Replica.init(std.testing.allocator, source_actor);
    defer source.deinit();
    var target = try Replica.init(std.testing.allocator, target_actor);
    defer target.deinit();

    const root_id = try source.insert(0, "A");
    var root = try source.change(root_id, std.testing.allocator);
    defer root.deinit(std.testing.allocator);
    _ = try target.receive(&root);

    var bad_operation = try Operation.initInsert(std.testing.allocator, 99, "X");
    defer bad_operation.deinit(std.testing.allocator);
    var bad_change = try Change.init(
        std.testing.allocator,
        OpId{ .actor = bad_actor, .counter = 0 },
        &.{root_id},
        bad_operation,
    );
    defer bad_change.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidOperation, target.receive(&bad_change));
    try std.testing.expectEqual(@as(usize, 1), target.events.items.len);
    const after_rejection = try target.text(std.testing.allocator);
    defer std.testing.allocator.free(after_rejection);
    try std.testing.expectEqualStrings("A", after_rejection);

    _ = try target.insert(1, "B");
    const after_valid_edit = try target.text(std.testing.allocator);
    defer std.testing.allocator.free(after_valid_edit);
    try std.testing.expectEqualStrings("AB", after_valid_edit);
}

test "concurrent deletes of different characters converge" {
    const actor_a = [_]u8{0} ** 15 ++ [_]u8{1};
    const actor_b = [_]u8{0} ** 15 ++ [_]u8{2};
    var first = try Replica.init(std.testing.allocator, actor_a);
    defer first.deinit();
    var second = try Replica.init(std.testing.allocator, actor_b);
    defer second.deinit();

    const root_id = try first.insert(0, "abc");
    var root = try first.change(root_id, std.testing.allocator);
    defer root.deinit(std.testing.allocator);
    _ = try second.receive(&root);

    const delete_a = try first.delete(0, 1);
    const delete_b = try second.delete(2, 1);
    var delete_a_change = try first.change(delete_a, std.testing.allocator);
    defer delete_a_change.deinit(std.testing.allocator);
    var delete_b_change = try second.change(delete_b, std.testing.allocator);
    defer delete_b_change.deinit(std.testing.allocator);
    _ = try first.receive(&delete_b_change);
    _ = try second.receive(&delete_a_change);

    const first_text = try first.text(std.testing.allocator);
    defer std.testing.allocator.free(first_text);
    const second_text = try second.text(std.testing.allocator);
    defer std.testing.allocator.free(second_text);
    try std.testing.expectEqualStrings("b", first_text);
    try std.testing.expectEqualStrings(first_text, second_text);
}

test "concurrent deletes of the same character are idempotent" {
    const actor_a = [_]u8{0} ** 15 ++ [_]u8{1};
    const actor_b = [_]u8{0} ** 15 ++ [_]u8{2};
    var first = try Replica.init(std.testing.allocator, actor_a);
    defer first.deinit();
    var second = try Replica.init(std.testing.allocator, actor_b);
    defer second.deinit();

    const root_id = try first.insert(0, "abc");
    var root = try first.change(root_id, std.testing.allocator);
    defer root.deinit(std.testing.allocator);
    _ = try second.receive(&root);

    const delete_a = try first.delete(1, 1);
    const delete_b = try second.delete(1, 1);
    var delete_a_change = try first.change(delete_a, std.testing.allocator);
    defer delete_a_change.deinit(std.testing.allocator);
    var delete_b_change = try second.change(delete_b, std.testing.allocator);
    defer delete_b_change.deinit(std.testing.allocator);
    _ = try first.receive(&delete_b_change);
    _ = try second.receive(&delete_a_change);

    const rendered = try first.text(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("ac", rendered);
}

test "overlapping concurrent delete ranges remove the union" {
    const actor_a = [_]u8{0} ** 15 ++ [_]u8{110};
    const actor_b = [_]u8{0} ** 15 ++ [_]u8{111};
    var first = try Replica.init(std.testing.allocator, actor_a);
    defer first.deinit();
    var second = try Replica.init(std.testing.allocator, actor_b);
    defer second.deinit();

    const root_id = try first.insert(0, "abcdef");
    var root = try first.change(root_id, std.testing.allocator);
    defer root.deinit(std.testing.allocator);
    _ = try second.receive(&root);

    const first_delete_id = try first.delete(1, 3); // bcd
    const second_delete_id = try second.delete(2, 3); // cde
    var first_delete = try first.change(first_delete_id, std.testing.allocator);
    defer first_delete.deinit(std.testing.allocator);
    var second_delete = try second.change(second_delete_id, std.testing.allocator);
    defer second_delete.deinit(std.testing.allocator);

    _ = try first.receive(&second_delete);
    _ = try second.receive(&first_delete);
    try std.testing.expectEqualStrings("af", first.textView());
    try std.testing.expectEqualStrings(first.textView(), second.textView());
}

test "an insertion after a deleted anchor remains ordered when branches merge" {
    const actor_a = [_]u8{0} ** 15 ++ [_]u8{112};
    const actor_b = [_]u8{0} ** 15 ++ [_]u8{113};
    var first = try Replica.init(std.testing.allocator, actor_a);
    defer first.deinit();
    var second = try Replica.init(std.testing.allocator, actor_b);
    defer second.deinit();

    const root_id = try first.insert(0, "abc");
    var root = try first.change(root_id, std.testing.allocator);
    defer root.deinit(std.testing.allocator);
    _ = try second.receive(&root);

    _ = try first.delete(1, 1); // hide b while retaining its anchor
    const branch_id = try second.insert(1, "X");
    var branch = try second.change(branch_id, std.testing.allocator);
    defer branch.deinit(std.testing.allocator);

    var deletion = try first.change(.{ .actor = actor_a, .counter = 1 }, std.testing.allocator);
    defer deletion.deinit(std.testing.allocator);
    _ = try first.receive(&branch);
    _ = try second.receive(&deletion);

    try std.testing.expectEqualStrings("aXc", first.textView());
    try std.testing.expectEqualStrings(first.textView(), second.textView());
}

test "loading a truncated save reports an incomplete frame" {
    const actor = [_]u8{0} ** 15 ++ [_]u8{1};
    var replica = try Replica.init(std.testing.allocator, actor);
    defer replica.deinit();
    _ = try replica.insert(0, "abc");

    const encoded = try replica.save(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectError(error.UnexpectedEnd, Replica.load(std.testing.allocator, encoded[0 .. encoded.len - 1]));
}

test "loading a save with a bad magic is rejected" {
    var bytes = [_]u8{0} ** 33;
    try std.testing.expectError(error.InvalidFormat, Replica.load(std.testing.allocator, &bytes));
}

test "loading a save with a corrupted frame reports a checksum mismatch" {
    const actor = [_]u8{0} ** 15 ++ [_]u8{1};
    var replica = try Replica.init(std.testing.allocator, actor);
    defer replica.deinit();
    _ = try replica.insert(0, "abc");

    const encoded = try replica.save(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    var corrupted = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(corrupted);
    corrupted[corrupted.len - 1] ^= 0x01;

    try std.testing.expectError(error.ChecksumMismatch, Replica.load(std.testing.allocator, corrupted));
}

test "replica indexes Unicode scalars rather than UTF-8 bytes" {
    const actor = [_]u8{0} ** 15 ++ [_]u8{1};
    var replica = try Replica.init(std.testing.allocator, actor);
    defer replica.deinit();

    _ = try replica.insert(0, "café");
    _ = try replica.insert(4, "!");

    const rendered = try replica.text(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("café!", rendered);
}

fn allocationFailureLocalAndReceive(allocator: std.mem.Allocator) !void {
    const source_actor = [_]u8{0} ** 15 ++ [_]u8{111};
    const target_actor = [_]u8{0} ** 15 ++ [_]u8{112};
    var source = try Replica.init(allocator, source_actor);
    defer source.deinit();
    var target = try Replica.init(allocator, target_actor);
    defer target.deinit();

    const inserted_id = try source.insert(0, "allocation");
    var inserted = try source.change(inserted_id, allocator);
    defer inserted.deinit(allocator);
    _ = try target.receive(&inserted);

    const deleted_id = try source.delete(1, 2);
    var deleted = try source.change(deleted_id, allocator);
    defer deleted.deinit(allocator);
    _ = try target.receive(&deleted);
}

test "local edits and receive are allocation-failure atomic" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationFailureLocalAndReceive,
        .{},
    );
}

fn allocationFailureApplyGroup(allocator: std.mem.Allocator) !void {
    const actor = [_]u8{0} ** 15 ++ [_]u8{113};
    var replica = try Replica.init(allocator, actor);
    defer replica.deinit();
    _ = try replica.insert(0, "base");

    const edits = [_]Edit{
        .{ .insert = .{ .index = 2, .text = "é" } },
        .{ .delete = .{ .index = 0, .length = 1 } },
    };
    var group = try replica.applyGroup(&edits, allocator);
    defer group.deinit(allocator);
}

test "applyGroup is allocation-failure atomic" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationFailureApplyGroup,
        .{},
    );
}

fn allocationFailurePendingDelivery(allocator: std.mem.Allocator) !void {
    const source_actor = [_]u8{0} ** 15 ++ [_]u8{113};
    const target_actor = [_]u8{0} ** 15 ++ [_]u8{114};
    var source = try Replica.init(allocator, source_actor);
    defer source.deinit();
    var target = try Replica.init(allocator, target_actor);
    defer target.deinit();

    const parent_id = try source.insert(0, "parent");
    const child_id = try source.insert(6, "child");
    var parent = try source.change(parent_id, allocator);
    defer parent.deinit(allocator);
    var child = try source.change(child_id, allocator);
    defer child.deinit(allocator);

    try std.testing.expectEqual(ReceiveResult.pending, try target.receive(&child));
    try std.testing.expectEqual(ReceiveResult.applied, try target.receive(&parent));
    try std.testing.expectEqual(@as(usize, 0), target.pendingCount());
}

test "pending delivery and retry are allocation-failure atomic" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationFailurePendingDelivery,
        .{},
    );
}

fn allocationFailurePersistenceAndReplay(allocator: std.mem.Allocator) !void {
    const source_actor = [_]u8{0} ** 15 ++ [_]u8{115};
    const target_actor = [_]u8{0} ** 15 ++ [_]u8{116};
    var source = try Replica.init(allocator, source_actor);
    defer source.deinit();
    var target = try Replica.init(allocator, target_actor);
    defer target.deinit();

    const first_id = try source.insert(0, "persist");
    const second_id = try source.insert(7, "ed");

    const snapshot = try source.save(allocator);
    defer allocator.free(snapshot);
    var restored = try Replica.load(allocator, snapshot);
    defer restored.deinit();
    try std.testing.expectEqualStrings(source.textView(), restored.textView());

    var first = try source.change(first_id, allocator);
    defer first.deinit(allocator);
    var second = try source.change(second_id, allocator);
    defer second.deinit(allocator);

    var log = ChangeLog.init(allocator);
    defer log.deinit();
    try log.append(&second);
    try log.append(&first);
    const result = try log.replay(target, .{});
    try std.testing.expectEqual(@as(usize, 2), result.frames);
    try std.testing.expectEqual(@as(usize, 2), target.historyCount());
    try std.testing.expectEqualStrings(source.textView(), target.textView());
}

test "save load and ChangeLog replay are allocation-failure atomic" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationFailurePersistenceAndReplay,
        .{},
    );
}

test "textView borrows current bytes without an allocation" {
    const actor = [_]u8{0} ** 15 ++ [_]u8{1};
    var replica = try Replica.init(std.testing.allocator, actor);
    defer replica.deinit();

    _ = try replica.insert(0, "hello");
    try std.testing.expectEqualStrings("hello", replica.textView());
}

test "read-only inspection reports history, pending changes, and frontier" {
    const source_actor = [_]u8{0} ** 15 ++ [_]u8{1};
    const target_actor = [_]u8{0} ** 15 ++ [_]u8{2};
    var source = try Replica.init(std.testing.allocator, source_actor);
    defer source.deinit();
    var target = try Replica.init(std.testing.allocator, target_actor);
    defer target.deinit();

    try std.testing.expectEqual(@as(usize, 0), target.historyCount());
    try std.testing.expectEqual(@as(usize, 0), target.pendingCount());
    const root_id = try source.insert(0, "A");
    const child_id = try source.insert(1, "B");
    var child = try source.change(child_id, std.testing.allocator);
    defer child.deinit(std.testing.allocator);
    _ = try target.receive(&child);

    try std.testing.expectEqual(@as(usize, 0), target.historyCount());
    try std.testing.expectEqual(@as(usize, 1), target.pendingCount());
    var root = try source.change(root_id, std.testing.allocator);
    defer root.deinit(std.testing.allocator);
    _ = try target.receive(&root);

    try std.testing.expectEqual(@as(usize, 2), target.historyCount());
    try std.testing.expectEqual(@as(usize, 0), target.pendingCount());
    try std.testing.expectEqual(@as(usize, 1), target.frontierView().len);
    try std.testing.expect(OpId.eql(child_id, target.frontierView()[0]));
}

test "have summarizes accepted IDs and excludes pending changes" {
    const source_actor = [_]u8{0} ** 15 ++ [_]u8{61};
    const target_actor = [_]u8{0} ** 15 ++ [_]u8{62};
    var source = try Replica.init(std.testing.allocator, source_actor);
    defer source.deinit();
    var target = try Replica.init(std.testing.allocator, target_actor);
    defer target.deinit();

    const parent_id = try source.insert(0, "A");
    const child_id = try source.insert(1, "B");
    var parent = try source.change(parent_id, std.testing.allocator);
    defer parent.deinit(std.testing.allocator);
    var child = try source.change(child_id, std.testing.allocator);
    defer child.deinit(std.testing.allocator);

    try std.testing.expectEqual(ReceiveResult.pending, try target.receive(&child));
    var target_have = try target.have(std.testing.allocator);
    defer target_have.deinit();
    try std.testing.expect(target_have.isEmpty());

    try std.testing.expectEqual(ReceiveResult.applied, try target.receive(&parent));
    var complete_have = try target.have(std.testing.allocator);
    defer complete_have.deinit();
    try std.testing.expectEqual(@as(usize, 1), complete_have.rangeCount());
    try std.testing.expect(complete_have.contains(parent_id));
    try std.testing.expect(complete_have.contains(child_id));
}

test "encodeHave exposes the same canonical summary as have" {
    const actor_id = [_]u8{0} ** 15 ++ [_]u8{64};
    var replica = try Replica.init(std.testing.allocator, actor_id);
    defer replica.deinit();
    _ = try replica.insert(0, "A");
    _ = try replica.insert(1, "B");

    const encoded = try replica.encodeHave(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    var decoded = try Have.decode(std.testing.allocator, encoded, .{});
    defer decoded.deinit();
    try std.testing.expect(decoded.contains(.{ .actor = actor_id, .counter = 0 }));
    try std.testing.expect(decoded.contains(.{ .actor = actor_id, .counter = 1 }));
}

test "changesForHave sends a missing parent before a known child hole" {
    const source_actor = [_]u8{0} ** 15 ++ [_]u8{63};
    var source = try Replica.init(std.testing.allocator, source_actor);
    defer source.deinit();

    _ = try source.insert(0, "A");
    const child_id = try source.insert(1, "B");
    const parent_id = OpId{ .actor = source_actor, .counter = 0 };

    var known = Have.init(std.testing.allocator);
    defer known.deinit();
    try known.add(child_id);

    var missing = try source.changesForHave(&known, std.testing.allocator);
    defer deinitBatch(&missing, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), missing.items.len);
    try std.testing.expect(missing.items[0].id.eql(parent_id));
}

test "SyncCursor repeats an unacknowledged batch and resumes after acknowledgement" {
    const source_actor = [_]u8{0} ** 15 ++ [_]u8{65};
    const target_actor = [_]u8{0} ** 15 ++ [_]u8{66};
    var source = try Replica.init(std.testing.allocator, source_actor);
    defer source.deinit();
    var target = try Replica.init(std.testing.allocator, target_actor);
    defer target.deinit();

    _ = try source.insert(0, "A");
    _ = try source.insert(1, "B");
    _ = try source.insert(2, "C");

    var initial = Have.init(std.testing.allocator);
    defer initial.deinit();
    var cursor = try SyncCursor.init(std.testing.allocator, &initial);
    defer cursor.deinit();

    var first = try cursor.next(source, 1, std.testing.allocator);
    defer first.deinit(std.testing.allocator);
    var retry = try cursor.next(source, 1, std.testing.allocator);
    defer retry.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), first.len());
    try std.testing.expectEqual(@as(usize, 1), retry.len());
    try std.testing.expect(first.changes.items[0].id.eql(retry.changes.items[0].id));
    try std.testing.expectEqual(@as(usize, 0), cursor.known.rangesView().len);

    _ = try target.receive(&first.changes.items[0]);
    try cursor.acknowledge(&first);

    var second = try cursor.next(source, 2, std.testing.allocator);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), second.len());
    for (second.changes.items) |*change| _ = try target.receive(change);
    try cursor.acknowledge(&second);

    var done = try cursor.next(source, 1, std.testing.allocator);
    defer done.deinit(std.testing.allocator);
    try std.testing.expect(done.isEmpty());
    try std.testing.expectEqualStrings(source.textView(), target.textView());
}

test "SyncCursor repairs a pending child without resending known changes" {
    const source_actor = [_]u8{0} ** 15 ++ [_]u8{67};
    const target_actor = [_]u8{0} ** 15 ++ [_]u8{68};
    var source = try Replica.init(std.testing.allocator, source_actor);
    defer source.deinit();
    var target = try Replica.init(std.testing.allocator, target_actor);
    defer target.deinit();

    const parent_id = try source.insert(0, "A");
    const child_id = try source.insert(1, "B");
    var parent = try source.change(parent_id, std.testing.allocator);
    defer parent.deinit(std.testing.allocator);
    var child = try source.change(child_id, std.testing.allocator);
    defer child.deinit(std.testing.allocator);

    try std.testing.expectEqual(ReceiveResult.pending, try target.receive(&child));

    var target_have = Have.init(std.testing.allocator);
    defer target_have.deinit();
    try target_have.add(child_id);
    var cursor = try SyncCursor.init(std.testing.allocator, &target_have);
    defer cursor.deinit();

    var repair = try cursor.next(source, 1, std.testing.allocator);
    defer repair.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), repair.len());
    try std.testing.expect(repair.changes.items[0].id.eql(parent_id));

    _ = try target.receive(&repair.changes.items[0]);
    try cursor.acknowledge(&repair);
    var done = try cursor.next(source, 1, std.testing.allocator);
    defer done.deinit(std.testing.allocator);
    try std.testing.expect(done.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), target.pendingCount());
    try std.testing.expectEqualStrings("AB", target.textView());
}

test "SyncCursor reconnect loop converges with bounded reverse batches" {
    const actors = [_]ActorId{
        [_]u8{0} ** 15 ++ [_]u8{69},
        [_]u8{0} ** 15 ++ [_]u8{70},
        [_]u8{0} ** 15 ++ [_]u8{71},
    };
    var replicas: [3]*Replica = undefined;
    for (&replicas, actors) |*slot, actor_id| slot.* = try Replica.init(std.testing.allocator, actor_id);
    defer for (replicas) |replica| replica.deinit();

    const root_id = try replicas[0].insert(0, "root");
    var root = try replicas[0].change(root_id, std.testing.allocator);
    defer root.deinit(std.testing.allocator);
    for (replicas[1..]) |replica| _ = try replica.receive(&root);

    _ = try replicas[0].insert(4, "A");
    _ = try replicas[1].insert(0, "B");
    _ = try replicas[2].insert(2, "C");

    // Each pair represents a reconnect. The sender is split into batches of
    // two, and each batch is delivered backwards so children are queued until
    // their parents arrive. Acknowledgement happens only after the whole batch
    // has been accepted or drained.
    for (replicas, 0..) |target, target_index| {
        for (replicas, 0..) |source, source_index| {
            if (target_index == source_index) continue;

            var peer_have = try target.have(std.testing.allocator);
            defer peer_have.deinit();
            var cursor = try SyncCursor.init(std.testing.allocator, &peer_have);
            defer cursor.deinit();

            while (true) {
                var batch = try cursor.next(source, 2, std.testing.allocator);
                defer batch.deinit(std.testing.allocator);
                if (batch.isEmpty()) break;

                var i = batch.changes.items.len;
                while (i > 0) {
                    i -= 1;
                    _ = try target.receive(&batch.changes.items[i]);
                }
                try cursor.acknowledge(&batch);
            }
            try std.testing.expectEqual(@as(usize, 0), target.pendingCount());
        }
    }

    for (replicas[1..]) |replica| {
        try std.testing.expectEqualStrings(replicas[0].textView(), replica.textView());
    }
}

test "SyncCursor rejects a zero batch limit without changing knowledge" {
    const source_actor = [_]u8{0} ** 15 ++ [_]u8{117};
    const target_actor = [_]u8{0} ** 15 ++ [_]u8{118};
    var source = try Replica.init(std.testing.allocator, source_actor);
    defer source.deinit();
    var target = try Replica.init(std.testing.allocator, target_actor);
    defer target.deinit();
    _ = try source.insert(0, "A");

    var known = try target.have(std.testing.allocator);
    defer known.deinit();
    var cursor = try SyncCursor.init(std.testing.allocator, &known);
    defer cursor.deinit();
    try std.testing.expectError(
        error.InvalidBatchLimit,
        cursor.next(source, 0, std.testing.allocator),
    );
    try std.testing.expect(cursor.known.rangesView().len == 0);
}

fn allocationFailureSyncCursor(allocator: std.mem.Allocator) !void {
    const source_actor = [_]u8{0} ** 15 ++ [_]u8{119};
    var source = try Replica.init(allocator, source_actor);
    defer source.deinit();
    _ = try source.insert(0, "cursor");

    var known = Have.init(allocator);
    defer known.deinit();
    var cursor = try SyncCursor.init(allocator, &known);
    defer cursor.deinit();
    var batch = try cursor.next(source, 1, allocator);
    defer batch.deinit(allocator);
    try cursor.acknowledge(&batch);
}

test "SyncCursor acknowledgement is allocation-failure atomic" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationFailureSyncCursor,
        .{},
    );
}

test "an invalid local UTF-8 edit changes neither history nor text" {
    const actor = [_]u8{0} ** 15 ++ [_]u8{1};
    var replica = try Replica.init(std.testing.allocator, actor);
    defer replica.deinit();

    try std.testing.expectError(error.InvalidUtf8, replica.insert(0, "\xff"));
    try std.testing.expectEqual(@as(usize, 0), replica.events.items.len);
    const rendered = try replica.text(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("", rendered);
}

test "three replicas converge after mixed offline edits and adversarial delivery" {
    const actor_a = [_]u8{0} ** 15 ++ [_]u8{1};
    const actor_b = [_]u8{0} ** 15 ++ [_]u8{2};
    const actor_c = [_]u8{0} ** 15 ++ [_]u8{3};
    var first = try Replica.init(std.testing.allocator, actor_a);
    defer first.deinit();
    var second = try Replica.init(std.testing.allocator, actor_b);
    defer second.deinit();
    var third = try Replica.init(std.testing.allocator, actor_c);
    defer third.deinit();

    _ = try first.insert(0, "A");
    _ = try first.insert(1, "a");
    _ = try first.delete(0, 1);

    _ = try second.insert(0, "B");
    _ = try second.insert(0, "b");
    _ = try second.delete(0, 1);

    _ = try third.insert(0, "C");
    _ = try third.insert(1, "é");

    var empty = Version{};
    var first_changes = try first.changesSince(&empty, std.testing.allocator);
    defer deinitBatch(&first_changes, std.testing.allocator);
    var second_changes = try second.changesSince(&empty, std.testing.allocator);
    defer deinitBatch(&second_changes, std.testing.allocator);
    var third_changes = try third.changesSince(&empty, std.testing.allocator);
    defer deinitBatch(&third_changes, std.testing.allocator);

    try deliverBatch(first, &third_changes, true);
    try deliverBatch(first, &second_changes, false);
    try deliverBatch(first, &first_changes, true);

    try deliverBatch(second, &first_changes, true);
    try deliverBatch(second, &third_changes, false);
    try deliverBatch(second, &second_changes, false);

    try deliverBatch(third, &second_changes, true);
    try deliverBatch(third, &first_changes, false);
    try deliverBatch(third, &third_changes, true);

    const first_text = try first.text(std.testing.allocator);
    defer std.testing.allocator.free(first_text);
    const second_text = try second.text(std.testing.allocator);
    defer std.testing.allocator.free(second_text);
    const third_text = try third.text(std.testing.allocator);
    defer std.testing.allocator.free(third_text);
    try std.testing.expectEqualStrings(first_text, second_text);
    try std.testing.expectEqualStrings(first_text, third_text);
}

test "a local edit after merging multiple parents is replayable remotely" {
    const actor_a = [_]u8{0} ** 15 ++ [_]u8{71};
    const actor_b = [_]u8{0} ** 15 ++ [_]u8{72};
    var first = try Replica.init(std.testing.allocator, actor_a);
    defer first.deinit();
    var second = try Replica.init(std.testing.allocator, actor_b);
    defer second.deinit();

    const root_id = try first.insert(0, "abc");
    var root = try first.change(root_id, std.testing.allocator);
    defer root.deinit(std.testing.allocator);
    _ = try second.receive(&root);

    const first_branch_id = try first.insert(1, "X");
    const second_branch_id = try second.insert(2, "Y");
    var first_branch = try first.change(first_branch_id, std.testing.allocator);
    defer first_branch.deinit(std.testing.allocator);
    var second_branch = try second.change(second_branch_id, std.testing.allocator);
    defer second_branch.deinit(std.testing.allocator);

    _ = try first.receive(&second_branch);
    _ = try second.receive(&first_branch);
    try std.testing.expectEqual(@as(usize, 2), first.frontierView().len);
    try std.testing.expectEqualStrings(first.textView(), second.textView());

    const merged_edit_id = try first.insert(2, "Z");
    var merged_edit = try first.change(merged_edit_id, std.testing.allocator);
    defer merged_edit.deinit(std.testing.allocator);
    _ = try second.receive(&merged_edit);

    try std.testing.expectEqualStrings(first.textView(), second.textView());
    try expectWalkerMatchesOracle(first);
    try expectWalkerMatchesOracle(second);
}

test "walker replay matches the exhaustive oracle on a branching history" {
    const actor_a = [_]u8{0} ** 15 ++ [_]u8{1};
    const actor_b = [_]u8{0} ** 15 ++ [_]u8{2};
    var first = try Replica.init(std.testing.allocator, actor_a);
    defer first.deinit();
    var second = try Replica.init(std.testing.allocator, actor_b);
    defer second.deinit();

    const root_id = try first.insert(0, "abcd");
    var root = try first.change(root_id, std.testing.allocator);
    defer root.deinit(std.testing.allocator);
    _ = try second.receive(&root);

    const first_insert = try first.insert(1, "XY");
    const first_delete = try first.delete(3, 1);
    const second_insert = try second.insert(3, "é");
    const second_delete = try second.delete(0, 1);
    var first_insert_change = try first.change(first_insert, std.testing.allocator);
    defer first_insert_change.deinit(std.testing.allocator);
    var first_delete_change = try first.change(first_delete, std.testing.allocator);
    defer first_delete_change.deinit(std.testing.allocator);
    var second_insert_change = try second.change(second_insert, std.testing.allocator);
    defer second_insert_change.deinit(std.testing.allocator);
    var second_delete_change = try second.change(second_delete, std.testing.allocator);
    defer second_delete_change.deinit(std.testing.allocator);

    _ = try first.receive(&second_insert_change);
    _ = try first.receive(&second_delete_change);
    _ = try second.receive(&first_insert_change);
    _ = try second.receive(&first_delete_change);

    const walker_text = try first.text(std.testing.allocator);
    defer std.testing.allocator.free(walker_text);
    try first.rebuildOracle();
    const oracle_text = try first.text(std.testing.allocator);
    defer std.testing.allocator.free(oracle_text);
    try std.testing.expectEqualStrings(walker_text, oracle_text);
}

test "critical replay transforms a multi-scalar delete onto a divergent branch" {
    const actor_a = [_]u8{0} ** 15 ++ [_]u8{11};
    const actor_b = [_]u8{0} ** 15 ++ [_]u8{12};
    var first = try Replica.init(std.testing.allocator, actor_a);
    defer first.deinit();
    var second = try Replica.init(std.testing.allocator, actor_b);
    defer second.deinit();

    const root_id = try first.insert(0, "abcdef");
    var root = try first.change(root_id, std.testing.allocator);
    defer root.deinit(std.testing.allocator);
    _ = try second.receive(&root);

    const delete_id = try first.delete(1, 2);
    const insert_id = try second.insert(0, "X");
    var delete_change = try first.change(delete_id, std.testing.allocator);
    defer delete_change.deinit(std.testing.allocator);
    var insert_change = try second.change(insert_id, std.testing.allocator);
    defer insert_change.deinit(std.testing.allocator);

    _ = try second.receive(&delete_change);
    _ = try first.receive(&insert_change);

    const before_oracle = try second.text(std.testing.allocator);
    defer std.testing.allocator.free(before_oracle);
    try second.rebuildOracle();
    const after_oracle = try second.text(std.testing.allocator);
    defer std.testing.allocator.free(after_oracle);
    try std.testing.expectEqualStrings(before_oracle, after_oracle);

    const first_text = try first.text(std.testing.allocator);
    defer std.testing.allocator.free(first_text);
    try std.testing.expectEqualStrings(first_text, after_oracle);
}

test "critical replay maps through a concurrent tombstone" {
    const actor_a = [_]u8{0} ** 15 ++ [_]u8{13};
    const actor_b = [_]u8{0} ** 15 ++ [_]u8{14};
    var first = try Replica.init(std.testing.allocator, actor_a);
    defer first.deinit();
    var second = try Replica.init(std.testing.allocator, actor_b);
    defer second.deinit();

    const root_id = try first.insert(0, "abcdef");
    var root = try first.change(root_id, std.testing.allocator);
    defer root.deinit(std.testing.allocator);
    _ = try second.receive(&root);

    const local_delete = try first.delete(0, 1);
    const remote_delete = try second.delete(2, 2);
    var local_change = try first.change(local_delete, std.testing.allocator);
    defer local_change.deinit(std.testing.allocator);
    var remote_change = try second.change(remote_delete, std.testing.allocator);
    defer remote_change.deinit(std.testing.allocator);

    _ = try first.receive(&remote_change);
    _ = try second.receive(&local_change);

    const first_text = try first.text(std.testing.allocator);
    defer std.testing.allocator.free(first_text);
    const second_text = try second.text(std.testing.allocator);
    defer std.testing.allocator.free(second_text);
    try std.testing.expectEqualStrings("bef", first_text);
    try std.testing.expectEqualStrings(first_text, second_text);

    const before_oracle = try first.text(std.testing.allocator);
    defer std.testing.allocator.free(before_oracle);
    try first.rebuildOracle();
    const after_oracle = try first.text(std.testing.allocator);
    defer std.testing.allocator.free(after_oracle);
    try std.testing.expectEqualStrings(before_oracle, after_oracle);
}

test "critical replay keeps a concurrent insertion when deleting its old range" {
    const actor_a = [_]u8{0} ** 15 ++ [_]u8{15};
    const actor_b = [_]u8{0} ** 15 ++ [_]u8{16};
    var first = try Replica.init(std.testing.allocator, actor_a);
    defer first.deinit();
    var second = try Replica.init(std.testing.allocator, actor_b);
    defer second.deinit();

    const root_id = try first.insert(0, "abc");
    var root = try first.change(root_id, std.testing.allocator);
    defer root.deinit(std.testing.allocator);
    _ = try second.receive(&root);

    const local_insert = try first.insert(1, "X");
    const remote_delete = try second.delete(0, 3);
    var local_change = try first.change(local_insert, std.testing.allocator);
    defer local_change.deinit(std.testing.allocator);
    var remote_change = try second.change(remote_delete, std.testing.allocator);
    defer remote_change.deinit(std.testing.allocator);

    _ = try first.receive(&remote_change);
    _ = try second.receive(&local_change);

    const first_text = try first.text(std.testing.allocator);
    defer std.testing.allocator.free(first_text);
    const second_text = try second.text(std.testing.allocator);
    defer std.testing.allocator.free(second_text);
    try std.testing.expectEqualStrings("X", first_text);
    try std.testing.expectEqualStrings(first_text, second_text);
}

test "overlapping concurrent deletes converge under duplicate out-of-order delivery" {
    const actors = [_]ActorId{
        [_]u8{0} ** 15 ++ [_]u8{41},
        [_]u8{0} ** 15 ++ [_]u8{42},
        [_]u8{0} ** 15 ++ [_]u8{43},
    };
    var replicas: [3]*Replica = undefined;
    for (&replicas, actors) |*slot, actor| slot.* = try Replica.init(std.testing.allocator, actor);
    defer for (replicas) |replica| replica.deinit();

    const root_id = try replicas[0].insert(0, "abcdefghij");
    var root = try replicas[0].change(root_id, std.testing.allocator);
    defer root.deinit(std.testing.allocator);
    for (replicas[1..]) |replica| _ = try replica.receive(&root);

    // These ranges overlap in the shared base: c..g, e..h, and b..d.
    _ = try replicas[0].delete(2, 5);
    _ = try replicas[0].insert(2, "X");
    _ = try replicas[1].delete(4, 4);
    _ = try replicas[1].insert(1, "Y");
    _ = try replicas[2].delete(1, 3);
    _ = try replicas[2].insert(0, "Z");

    var empty = Version{};
    var batches: [3]std.ArrayList(Change) = .{ .empty, .empty, .empty };
    defer for (&batches) |*batch| deinitBatch(batch, std.testing.allocator);
    for (&batches, replicas) |*batch, replica| batch.* = try replica.changesSince(&empty, std.testing.allocator);

    for (replicas, 0..) |target, target_index| {
        for (&batches, 0..) |*batch, source_index| {
            if (target_index == source_index) continue;
            // First send the child-to-parent order, which queues the branch;
            // then send the canonical order twice to exercise draining and
            // duplicate handling.
            try deliverBatch(target, batch, true);
            try deliverBatch(target, batch, false);
            try deliverBatch(target, batch, false);
            try std.testing.expectEqual(@as(usize, 0), target.pendingCount());
            try expectWalkerMatchesOracle(target);
        }
    }

    // This edit is causally after all three branch tips on replicas[0]. It
    // exercises replay of a new operation whose parent frontier has several
    // heads, then ships that merged edit to peers in reverse order.
    const merged_id = try replicas[0].insert(replicas[0].visibleCount() / 2, "M");
    var merged = try replicas[0].change(merged_id, std.testing.allocator);
    defer merged.deinit(std.testing.allocator);
    for (replicas[1..]) |replica| {
        _ = try replica.receive(&merged);
        _ = try replica.receive(&merged);
    }

    const expected = try std.testing.allocator.dupe(u8, replicas[0].textView());
    defer std.testing.allocator.free(expected);
    for (replicas) |replica| {
        try std.testing.expectEqualStrings(expected, replica.textView());
        try expectWalkerMatchesOracle(replica);
    }
}

fn expectWalkerMatchesOracle(replica: *Replica) !void {
    const walker_text = try replica.text(std.testing.allocator);
    defer std.testing.allocator.free(walker_text);

    try replica.rebuildOracle();
    const oracle_text = try replica.text(std.testing.allocator);
    defer std.testing.allocator.free(oracle_text);

    try std.testing.expectEqualStrings(oracle_text, walker_text);
}

test "generated branching histories match the exhaustive replay oracle" {
    const actors = [_]ActorId{
        [_]u8{0} ** 15 ++ [_]u8{21},
        [_]u8{0} ** 15 ++ [_]u8{22},
        [_]u8{0} ** 15 ++ [_]u8{23},
        [_]u8{0} ** 15 ++ [_]u8{24},
    };
    const snippets = [_][]const u8{ "a", "β", "XY", "🙂", "中" };

    var seed_index: usize = 0;
    while (seed_index < 8) : (seed_index += 1) {
        var replicas: [4]*Replica = undefined;
        for (&replicas, actors) |*slot, actor_id| slot.* = try Replica.init(std.testing.allocator, actor_id);
        defer for (replicas) |replica| replica.deinit();

        var random_state: u64 = 0x9e3779b97f4a7c15 ^ @as(u64, seed_index);
        for (replicas) |replica| {
            var edit_index: usize = 0;
            while (edit_index < 20) : (edit_index += 1) {
                const visible_count = replica.visibleCount();
                const do_insert = visible_count == 0 or nextTestRandom(&random_state) % 2 == 0;
                if (do_insert) {
                    const index = @as(usize, @intCast(nextTestRandom(&random_state) % (visible_count + 1)));
                    const snippet = snippets[@as(usize, @intCast(nextTestRandom(&random_state) % snippets.len))];
                    _ = try replica.insert(index, snippet);
                } else {
                    const index = @as(usize, @intCast(nextTestRandom(&random_state) % visible_count));
                    const length = @as(usize, @intCast(nextTestRandom(&random_state) % (visible_count - index))) + 1;
                    _ = try replica.delete(index, length);
                }
            }
        }

        var empty = Version{};
        var batches: [4]std.ArrayList(Change) = .{ .empty, .empty, .empty, .empty };
        defer for (&batches) |*batch| deinitBatch(batch, std.testing.allocator);
        for (&batches, replicas) |*batch, replica| {
            batch.* = try replica.changesSince(&empty, std.testing.allocator);
        }

        for (replicas, 0..) |target, target_index| {
            for (&batches, 0..) |*batch, source_index| {
                if (target_index == source_index) continue;
                try deliverBatch(target, batch, ((target_index + source_index + seed_index) % 2) == 0);
                try deliverBatch(target, batch, ((target_index + source_index + seed_index) % 2) != 0);
                try std.testing.expectEqual(@as(usize, 0), target.pendingCount());
                try expectWalkerMatchesOracle(target);
            }
        }

        for (replicas) |replica| try expectWalkerMatchesOracle(replica);
    }
}

fn nextTestRandom(state: *u64) u64 {
    state.* = state.* *% 6364136223846793005 +% 1442695040888963407;
    return state.*;
}

fn generateLocalEdits(replica: *Replica, random_state: *u64, edit_count: usize) !void {
    const snippets = [_][]const u8{ "a", "β", "XY", "🙂", "中" };
    var edit_index: usize = 0;
    while (edit_index < edit_count) : (edit_index += 1) {
        const visible_count = replica.visibleCount();
        const do_insert = visible_count == 0 or nextTestRandom(random_state) % 2 == 0;
        if (do_insert) {
            const index = @as(usize, @intCast(nextTestRandom(random_state) % (visible_count + 1)));
            const snippet = snippets[@as(usize, @intCast(nextTestRandom(random_state) % snippets.len))];
            _ = try replica.insert(index, snippet);
        } else {
            const index = @as(usize, @intCast(nextTestRandom(random_state) % visible_count));
            const length = @as(usize, @intCast(nextTestRandom(random_state) % (visible_count - index))) + 1;
            _ = try replica.delete(index, length);
        }
    }
}

test "generated multi-round merge DAGs match the exhaustive replay oracle" {
    const actors = [_]ActorId{
        [_]u8{0} ** 15 ++ [_]u8{51},
        [_]u8{0} ** 15 ++ [_]u8{52},
        [_]u8{0} ** 15 ++ [_]u8{53},
        [_]u8{0} ** 15 ++ [_]u8{54},
    };

    var seed_index: usize = 0;
    while (seed_index < 3) : (seed_index += 1) {
        var replicas: [4]*Replica = undefined;
        for (&replicas, actors) |*slot, actor| slot.* = try Replica.init(std.testing.allocator, actor);
        defer for (replicas) |replica| replica.deinit();

        var random_state: u64 = 0x243f6a8885a308d3 ^ @as(u64, seed_index);
        const root_id = try replicas[0].insert(0, "base");
        var root = try replicas[0].change(root_id, std.testing.allocator);
        defer root.deinit(std.testing.allocator);
        for (replicas[1..]) |replica| _ = try replica.receive(&root);

        var round: usize = 0;
        while (round < 3) : (round += 1) {
            for (replicas) |replica| try generateLocalEdits(replica, &random_state, 6);

            // Each round exposes a different subset of branch tips. The
            // receiver therefore creates new events with a frontier that
            // may contain several incomparable parents.
            {
                var empty = Version{};
                var batches: [4]std.ArrayList(Change) = .{ .empty, .empty, .empty, .empty };
                defer for (&batches) |*batch| deinitBatch(batch, std.testing.allocator);
                for (&batches, replicas) |*batch, replica| batch.* = try replica.changesSince(&empty, std.testing.allocator);

                for (replicas, 0..) |target, target_index| {
                    const source_index = (target_index + round + 1) % replicas.len;
                    try deliverBatch(target, &batches[source_index], true);
                    try deliverBatch(target, &batches[source_index], false);
                    try std.testing.expectEqual(@as(usize, 0), target.pendingCount());
                    try expectWalkerMatchesOracle(target);
                }
            }

            for (replicas) |replica| try expectWalkerMatchesOracle(replica);
        }

        // Finish with full anti-entropy in both directions and duplicate every
        // batch. This turns the staged rounds into one common DAG tip set.
        {
            var empty = Version{};
            var batches: [4]std.ArrayList(Change) = .{ .empty, .empty, .empty, .empty };
            defer for (&batches) |*batch| deinitBatch(batch, std.testing.allocator);
            for (&batches, replicas) |*batch, replica| batch.* = try replica.changesSince(&empty, std.testing.allocator);
            for (replicas, 0..) |target, target_index| {
                for (&batches, 0..) |*batch, source_index| {
                    if (target_index == source_index) continue;
                    try deliverBatch(target, batch, ((target_index + source_index + seed_index) % 2) == 0);
                    try deliverBatch(target, batch, ((target_index + source_index + seed_index) % 2) != 0);
                    try std.testing.expectEqual(@as(usize, 0), target.pendingCount());
                    try expectWalkerMatchesOracle(target);
                }
            }
        }

        const expected = try std.testing.allocator.dupe(u8, replicas[0].textView());
        defer std.testing.allocator.free(expected);
        for (replicas) |replica| {
            try std.testing.expectEqualStrings(expected, replica.textView());
            try expectWalkerMatchesOracle(replica);
        }
    }
}

test "randomized offline replicas converge under reordering and duplicates" {
    const actors = [_]ActorId{
        [_]u8{0} ** 15 ++ [_]u8{1},
        [_]u8{0} ** 15 ++ [_]u8{2},
        [_]u8{0} ** 15 ++ [_]u8{3},
        [_]u8{0} ** 15 ++ [_]u8{4},
    };
    var replicas: [4]*Replica = undefined;
    for (&replicas, actors) |*slot, actor| slot.* = try Replica.init(std.testing.allocator, actor);
    defer {
        for (replicas) |replica| replica.deinit();
    }

    const snippets = [_][]const u8{ "a", "β", "XY", "🙂" };
    var random_state: u64 = 0x4d595df4d0f33173;
    for (replicas) |replica| {
        var edit_index: usize = 0;
        while (edit_index < 24) : (edit_index += 1) {
            const visible_count = replica.visibleCount();
            const should_insert = visible_count == 0 or (nextTestRandom(&random_state) % 3 != 0);
            if (should_insert) {
                const index = @as(usize, @intCast(nextTestRandom(&random_state) % (visible_count + 1)));
                const snippet = snippets[@as(usize, @intCast(nextTestRandom(&random_state) % snippets.len))];
                _ = try replica.insert(index, snippet);
            } else {
                const index = @as(usize, @intCast(nextTestRandom(&random_state) % visible_count));
                const max_length = visible_count - index;
                const length = @as(usize, @intCast(nextTestRandom(&random_state) % max_length)) + 1;
                _ = try replica.delete(index, length);
            }
        }
    }

    var empty = Version{};
    var batches: [4]std.ArrayList(Change) = .{ .empty, .empty, .empty, .empty };
    defer {
        for (&batches) |*batch| deinitBatch(batch, std.testing.allocator);
    }
    for (&batches, replicas) |*batch, replica| {
        batch.* = try replica.changesSince(&empty, std.testing.allocator);
    }

    for (replicas, 0..) |target, target_index| {
        for (&batches, 0..) |*batch, source_index| {
            if (target_index == source_index) continue;
            try deliverBatch(target, batch, ((target_index + source_index) % 2) == 0);
            // A second delivery exercises duplicate handling after the target
            // has already incorporated the complete branch.
            try deliverBatch(target, batch, ((target_index + source_index) % 2) != 0);
        }
    }

    const first_text = try replicas[0].text(std.testing.allocator);
    defer std.testing.allocator.free(first_text);
    for (replicas[1..]) |replica| {
        const text = try replica.text(std.testing.allocator);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings(first_text, text);
    }
}
