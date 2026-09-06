//! Small, deterministic benchmark and allocation-profiling harness for the
//! native collaborative text implementation.
//!
//! The harness intentionally lives outside the library API.  It measures the
//! end-to-end work performed by the public Replica, ChangeLog, and SyncCursor
//! surfaces while keeping the workload deterministic and checking convergence
//! as part of every replicated scenario.

const std = @import("std");
const Io = std.Io;
const collab = @import("collab");

const Replica = collab.Replica;
const ActorId = collab.ActorId;
const Ordering = collab.Ordering;

const BenchError = error{
    InvalidArgument,
    NonConverged,
    BenchmarkLeak,
};

const Scenario = enum {
    local,
    merge,
    persistence,
    sync,
};

const Config = struct {
    scenario: ?Scenario = null,
    edits: usize = 32,
    replicas: usize = 3,
    batch: usize = 32,
    repeat: usize = 1,
    seed: u64 = 0xC0FFEE,
    ordering: Ordering = .fugue_max,
    json: bool = false,
};

const WorkloadState = struct {
    work_units: usize,
    elapsed_ns: i96,
    ordering: Ordering,
    history_events: usize,
    pending_events: usize,
    frontier_heads: usize,
    text_bytes: usize,
    text_scalars: usize,
    snapshot_bytes: usize,
    checksum: u64,
    allocations: usize,
    resizes: usize,
    remaps: usize,
    frees: usize,
    total_requested_bytes: usize,
    peak_live_bytes: usize,
};

/// A thin allocator adapter that records the quantities useful when comparing
/// representations: allocation calls, resize/remap calls, total requested
/// bytes, and the peak live byte count.  It delegates all ownership to the
/// normal page allocator and is not part of the production API.
const Meter = struct {
    backing: std.mem.Allocator = std.heap.page_allocator,
    allocations: usize = 0,
    resizes: usize = 0,
    remaps: usize = 0,
    frees: usize = 0,
    active_bytes: usize = 0,
    peak_live_bytes: usize = 0,
    total_requested_bytes: usize = 0,

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *Meter) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn recordActive(self: *Meter) void {
        if (self.active_bytes > self.peak_live_bytes) {
            self.peak_live_bytes = self.active_bytes;
        }
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Meter = @ptrCast(@alignCast(context));
        const result = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocations += 1;
        self.active_bytes += len;
        self.total_requested_bytes += len;
        self.recordActive();
        return result;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *Meter = @ptrCast(@alignCast(context));
        const result = self.backing.rawResize(memory, alignment, new_len, ret_addr);
        if (!result) return false;

        self.resizes += 1;
        if (new_len >= memory.len) {
            const delta = new_len - memory.len;
            self.active_bytes += delta;
            self.total_requested_bytes += delta;
        } else {
            self.active_bytes -= memory.len - new_len;
        }
        self.recordActive();
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Meter = @ptrCast(@alignCast(context));
        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;

        self.remaps += 1;
        if (new_len >= memory.len) {
            const delta = new_len - memory.len;
            self.active_bytes += delta;
            self.total_requested_bytes += delta;
        } else {
            self.active_bytes -= memory.len - new_len;
        }
        self.recordActive();
        return result;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *Meter = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, ret_addr);
        self.frees += 1;
        self.active_bytes -= memory.len;
    }
};

const Prng = struct {
    state: u64,

    fn init(seed: u64) Prng {
        return .{ .state = if (seed == 0) 0x9E3779B97F4A7C15 else seed };
    }

    fn next(self: *Prng) u64 {
        var value = self.state;
        value ^= value << 13;
        value ^= value >> 7;
        value ^= value << 17;
        self.state = if (value == 0) 0x9E3779B97F4A7C15 else value;
        return self.state;
    }
};

fn actor(index: usize) ActorId {
    var result = [_]u8{0} ** 16;
    std.mem.writeInt(u64, result[0..8], @intCast(index), .little);
    return result;
}

fn insertPayload(index: usize) []const u8 {
    return switch (index % 5) {
        0 => "x",
        1 => "ab",
        2 => "é",
        3 => "xyz",
        else => "中",
    };
}

fn now(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn checksumText(replica: *const Replica) u64 {
    return std.hash.Wyhash.hash(0, replica.textView());
}

fn state(
    meter: *const Meter,
    stats: collab.ReplicaStats,
    work_units: usize,
    elapsed_ns: i96,
    snapshot_bytes: usize,
    checksum: u64,
) WorkloadState {
    return .{
        .work_units = work_units,
        .elapsed_ns = elapsed_ns,
        .ordering = stats.ordering,
        .history_events = stats.history_events,
        .pending_events = stats.pending_events,
        .frontier_heads = stats.frontier_heads,
        .text_bytes = stats.text_bytes,
        .text_scalars = stats.text_scalars,
        .snapshot_bytes = snapshot_bytes,
        .checksum = checksum,
        .allocations = meter.allocations,
        .resizes = meter.resizes,
        .remaps = meter.remaps,
        .frees = meter.frees,
        .total_requested_bytes = meter.total_requested_bytes,
        .peak_live_bytes = meter.peak_live_bytes,
    };
}

fn generateEdits(replica: *Replica, edits: usize, seed: u64) !void {
    var rng = Prng.init(seed);
    for (0..edits) |edit_index| {
        const visible = replica.visibleScalarCount();
        if (visible == 0 or rng.next() % 4 != 0) {
            const index = if (visible == 0) 0 else @as(usize, @intCast(rng.next() % (visible + 1)));
            _ = try replica.insert(index, insertPayload(edit_index));
        } else {
            const index = @as(usize, @intCast(rng.next() % visible));
            const remaining = visible - index;
            const length = @as(usize, @intCast(1 + (rng.next() % @min(remaining, 3))));
            _ = try replica.delete(index, length);
        }
    }
}

fn runLocal(io: Io, meter: *Meter, config: Config) !WorkloadState {
    const allocator = meter.allocator();
    var replica = try Replica.initWithOrdering(allocator, actor(1), config.ordering);
    defer replica.deinit();

    const start = now(io);
    try generateEdits(replica, config.edits, config.seed);
    const elapsed = now(io) - start;
    const stats = replica.stats();
    return state(meter, stats, config.edits, elapsed, 0, checksumText(replica));
}

fn runMerge(io: Io, meter: *Meter, config: Config) !WorkloadState {
    if (config.replicas < 2) return BenchError.InvalidArgument;

    const allocator = meter.allocator();
    const replicas = try allocator.alloc(*Replica, config.replicas);
    var created: usize = 0;
    errdefer {
        for (replicas[0..created]) |replica| replica.deinit();
        allocator.free(replicas);
    }
    for (replicas, 0..) |*slot, i| {
        slot.* = try Replica.initWithOrdering(allocator, actor(10 + i), config.ordering);
        created += 1;
    }

    const start = now(io);
    for (replicas, 0..) |replica, i| {
        try generateEdits(replica, config.edits, config.seed +% @as(u64, @intCast(i + 1)));
    }

    var delivered: usize = 0;
    // A bounded number of rounds is enough to make every source observe all
    // previous sources.  The final equality check turns a missed dependency
    // into a benchmark failure rather than a misleading timing result.
    for (0..config.replicas + 1) |_| {
        var round_delivered: usize = 0;
        for (replicas, 0..) |source, source_index| {
            for (replicas, 0..) |target, target_index| {
                if (source_index == target_index) continue;
                var have = try target.have(allocator);
                defer have.deinit();
                var batch = try source.changesForHave(&have, allocator);
                defer {
                    for (batch.items) |change| change.deinit(allocator);
                    batch.deinit(allocator);
                }
                for (batch.items) |*change| {
                    _ = try target.receive(change);
                    delivered += 1;
                    round_delivered += 1;
                }
            }
        }
        if (round_delivered == 0) break;
    }
    const elapsed = now(io) - start;

    const expected = replicas[0].textView();
    for (replicas[1..]) |replica| {
        if (!std.mem.eql(u8, expected, replica.textView())) return BenchError.NonConverged;
    }
    const stats = replicas[0].stats();
    const checksum = checksumText(replicas[0]);
    for (replicas) |replica| replica.deinit();
    allocator.free(replicas);
    created = 0;
    return state(meter, stats, config.edits * config.replicas + delivered, elapsed, 0, checksum);
}

fn runPersistence(io: Io, meter: *Meter, config: Config) !WorkloadState {
    const allocator = meter.allocator();
    var replica = try Replica.initWithOrdering(allocator, actor(1), config.ordering);
    defer replica.deinit();
    try generateEdits(replica, config.edits, config.seed);

    const start = now(io);
    const bytes = try replica.save(allocator);
    defer allocator.free(bytes);
    var loaded = try Replica.load(allocator, bytes);
    defer loaded.deinit();
    if (!std.mem.eql(u8, replica.textView(), loaded.textView())) return BenchError.NonConverged;
    const elapsed = now(io) - start;
    const stats = loaded.stats();
    return state(meter, stats, config.edits + 1, elapsed, bytes.len, checksumText(loaded));
}

fn runSync(io: Io, meter: *Meter, config: Config) !WorkloadState {
    if (config.batch == 0) return BenchError.InvalidArgument;

    const allocator = meter.allocator();
    var source = try Replica.initWithOrdering(allocator, actor(1), config.ordering);
    defer source.deinit();
    var target = try Replica.initWithOrdering(allocator, actor(2), config.ordering);
    defer target.deinit();
    try generateEdits(source, config.edits, config.seed);

    var initial_have = try target.have(allocator);
    defer initial_have.deinit();
    var cursor = try collab.SyncCursor.init(allocator, &initial_have);
    defer cursor.deinit();

    const start = now(io);
    var delivered: usize = 0;
    while (true) {
        var batch = try cursor.next(source, config.batch, allocator);
        defer batch.deinit(allocator);
        if (batch.isEmpty()) break;
        for (batch.changes.items) |*change| {
            _ = try target.receive(change);
            delivered += 1;
        }
        try cursor.acknowledge(&batch);
    }
    const elapsed = now(io) - start;
    if (!std.mem.eql(u8, source.textView(), target.textView())) return BenchError.NonConverged;
    const stats = target.stats();
    return state(meter, stats, config.edits + delivered, elapsed, 0, checksumText(target));
}

fn runScenario(io: Io, meter: *Meter, scenario: Scenario, config: Config) !WorkloadState {
    return switch (scenario) {
        .local => runLocal(io, meter, config),
        .merge => runMerge(io, meter, config),
        .persistence => runPersistence(io, meter, config),
        .sync => runSync(io, meter, config),
    };
}

fn scenarioName(scenario: Scenario) []const u8 {
    return switch (scenario) {
        .local => "local",
        .merge => "merge",
        .persistence => "persistence",
        .sync => "sync",
    };
}

fn parseScenario(value: []const u8) !Scenario {
    if (std.mem.eql(u8, value, "local")) return .local;
    if (std.mem.eql(u8, value, "merge")) return .merge;
    if (std.mem.eql(u8, value, "persistence")) return .persistence;
    if (std.mem.eql(u8, value, "sync")) return .sync;
    return BenchError.InvalidArgument;
}

fn printUsage(writer: *Io.Writer) !void {
    try writer.print(
        "usage: crdt-bench [options]\n" ++
            "  --scenario local|merge|persistence|sync|all\n" ++
            "  --edits N       local edits per replica (default: 32)\n" ++
            "  --replicas N    merge replica count (default: 3)\n" ++
            "  --batch N       sync batch size (default: 32)\n" ++
            "  --repeat N      samples per scenario (default: 1)\n" ++
            "  --seed N        deterministic workload seed\n" ++
            "  --ordering fugue|fugue-max (default: fugue-max)\n" ++
            "  --json          emit one JSON object per sample\n" ++
            "  --help          show this message\n",
        .{},
    );
}

fn parseArgs(args: []const []const u8, writer: *Io.Writer) !Config {
    var config = Config{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help")) {
            try printUsage(writer);
            return BenchError.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--json")) {
            config.json = true;
        } else if (std.mem.eql(u8, arg, "--scenario")) {
            i += 1;
            if (i >= args.len) return BenchError.InvalidArgument;
            if (std.mem.eql(u8, args[i], "all")) {
                config.scenario = null;
            } else {
                config.scenario = try parseScenario(args[i]);
            }
        } else if (std.mem.eql(u8, arg, "--edits")) {
            i += 1;
            if (i >= args.len) return BenchError.InvalidArgument;
            config.edits = try std.fmt.parseUnsigned(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--replicas")) {
            i += 1;
            if (i >= args.len) return BenchError.InvalidArgument;
            config.replicas = try std.fmt.parseUnsigned(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--batch")) {
            i += 1;
            if (i >= args.len) return BenchError.InvalidArgument;
            config.batch = try std.fmt.parseUnsigned(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--repeat")) {
            i += 1;
            if (i >= args.len) return BenchError.InvalidArgument;
            config.repeat = try std.fmt.parseUnsigned(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            i += 1;
            if (i >= args.len) return BenchError.InvalidArgument;
            config.seed = try std.fmt.parseUnsigned(u64, args[i], 0);
        } else if (std.mem.eql(u8, arg, "--ordering")) {
            i += 1;
            if (i >= args.len) return BenchError.InvalidArgument;
            if (std.mem.eql(u8, args[i], "fugue")) {
                config.ordering = .fugue;
            } else if (std.mem.eql(u8, args[i], "fugue-max") or std.mem.eql(u8, args[i], "fugue_max")) {
                config.ordering = .fugue_max;
            } else {
                return BenchError.InvalidArgument;
            }
        } else {
            return BenchError.InvalidArgument;
        }
    }
    if (config.repeat == 0 or config.replicas == 0) return BenchError.InvalidArgument;
    return config;
}

fn printResult(writer: *Io.Writer, scenario: Scenario, sample: usize, config: Config, result: WorkloadState) !void {
    const elapsed_u64: u64 = @intCast(@max(result.elapsed_ns, 0));
    const ns_per_work: u64 = if (result.work_units == 0) 0 else elapsed_u64 / result.work_units;
    if (config.json) {
        try writer.print(
            "{{\"scenario\":\"{s}\",\"ordering\":\"{s}\",\"sample\":{},\"edits\":{},\"replicas\":{},\"batch\":{},\"work_units\":{},\"elapsed_ns\":{},\"ns_per_work\":{},\"history_events\":{},\"pending_events\":{},\"frontier_heads\":{},\"text_bytes\":{},\"text_scalars\":{},\"snapshot_bytes\":{},\"checksum\":{},\"allocations\":{},\"resizes\":{},\"remaps\":{},\"frees\":{},\"total_requested_bytes\":{},\"peak_live_bytes\":{}}}\n",
            .{
                scenarioName(scenario),
                @tagName(result.ordering),
                sample,
                config.edits,
                config.replicas,
                config.batch,
                result.work_units,
                result.elapsed_ns,
                ns_per_work,
                result.history_events,
                result.pending_events,
                result.frontier_heads,
                result.text_bytes,
                result.text_scalars,
                result.snapshot_bytes,
                result.checksum,
                result.allocations,
                result.resizes,
                result.remaps,
                result.frees,
                result.total_requested_bytes,
                result.peak_live_bytes,
            },
        );
    } else {
        try writer.print(
            "scenario={s} ordering={s} sample={} work={} elapsed_ns={} ns_per_work={} history={} pending={} frontier={} text_bytes={} text_scalars={} snapshot_bytes={} allocations={} resizes={} remaps={} frees={} total_bytes={} peak_live_bytes={} checksum={x}\n",
            .{
                scenarioName(scenario),
                @tagName(result.ordering),
                sample,
                result.work_units,
                result.elapsed_ns,
                ns_per_work,
                result.history_events,
                result.pending_events,
                result.frontier_heads,
                result.text_bytes,
                result.text_scalars,
                result.snapshot_bytes,
                result.allocations,
                result.resizes,
                result.remaps,
                result.frees,
                result.total_requested_bytes,
                result.peak_live_bytes,
                result.checksum,
            },
        );
    }
}

fn finalizeMetrics(result: *WorkloadState, meter: *const Meter) !void {
    if (meter.active_bytes != 0) return BenchError.BenchmarkLeak;
    result.allocations = meter.allocations;
    result.resizes = meter.resizes;
    result.remaps = meter.remaps;
    result.frees = meter.frees;
    result.total_requested_bytes = meter.total_requested_bytes;
    result.peak_live_bytes = meter.peak_live_bytes;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    const args = try init.minimal.args.toSlice(arena);
    const config = parseArgs(args, stdout) catch |err| {
        if (err == BenchError.InvalidArgument) {
            try printUsage(stdout);
            try stdout.flush();
            return;
        }
        return err;
    };

    const scenarios = [_]Scenario{ .local, .merge, .persistence, .sync };
    if (config.scenario) |scenario| {
        for (0..config.repeat) |sample| {
            var meter = Meter{};
            var result = try runScenario(init.io, &meter, scenario, config);
            try finalizeMetrics(&result, &meter);
            try printResult(stdout, scenario, sample, config, result);
        }
    } else {
        for (scenarios) |scenario| {
            for (0..config.repeat) |sample| {
                var meter = Meter{};
                var result = try runScenario(init.io, &meter, scenario, config);
                try finalizeMetrics(&result, &meter);
                try printResult(stdout, scenario, sample, config, result);
            }
        }
    }
    try stdout.flush();
}
