//! Command-line entry point for the deterministic CRDT simulation lab.

const std = @import("std");
const Io = std.Io;
const sim = @import("simulator.zig");

const CliError = error{InvalidArgument};

const Config = struct {
    scenario: ?sim.Scenario = null,
    options: sim.ScenarioOptions = .{},
    sweep: usize = 1,
    progress_every: usize = 25,
    json: bool = false,
    trace: bool = false,
    help: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_file.interface;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file = Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_file.interface;

    var config = parseArgs(args) catch |err| {
        try stderr.print("invalid lab arguments: {s}\n\n", .{@errorName(err)});
        try printUsage(stderr);
        try stderr.flush();
        return err;
    };
    if (config.help) {
        try printUsage(stdout);
        try stdout.flush();
        return;
    }
    config.options.capture_trace = config.trace;

    const allocator = std.heap.smp_allocator;
    const scenarios = [_]sim.Scenario{ .offline, .partition, .reorder, .restart, .random };
    if (config.sweep > 1) {
        // Sweeps default to the generated scenario. A fixed scenario may be
        // selected explicitly to fuzz its transport decisions instead.
        try runSweep(init.io, allocator, config.scenario orelse .random, config, stdout, stderr);
    } else if (config.scenario) |scenario| {
        try runOne(allocator, scenario, config, stdout, stderr);
    } else {
        for (scenarios) |scenario| try runOne(allocator, scenario, config, stdout, stderr);
    }

    try stdout.flush();
    try stderr.flush();
}

fn runOne(
    allocator: std.mem.Allocator,
    scenario: sim.Scenario,
    config: Config,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !void {
    try stderr.print("lab: running {s} seed={}\n", .{ scenario.name(), config.options.seed });
    try stderr.flush();

    var failure_trace: std.ArrayList(u8) = .empty;
    defer failure_trace.deinit(allocator);
    var report = sim.runScenarioCapturingFailure(
        allocator,
        scenario,
        config.options,
        &failure_trace,
    ) catch |err| {
        try printFailure(stderr, scenario, config, config.options.seed, err, failure_trace.items);
        try stderr.flush();
        return err;
    };
    defer report.deinit();

    if (config.json) {
        try std.json.Stringify.value(.{
            .scenario = report.scenario.name(),
            .seed = report.seed,
            .replicas = report.replicas,
            .actions = report.actions,
            .settle_rounds = report.settle_rounds,
            .history_events = report.history_events,
            .text_scalars = report.text_scalars,
            .checksum = report.checksum,
            .final_text = report.final_text,
            .sync_attempts = report.network.sync_attempts,
            .blocked_syncs = report.network.blocked_syncs,
            .sent_changes = report.network.sent_changes,
            .queued_envelopes = report.network.queued_envelopes,
            .delivered_envelopes = report.network.delivered_envelopes,
            .dropped_changes = report.network.dropped_changes,
            .injected_duplicates = report.network.injected_duplicates,
            .pending_receives = report.network.pending_receives,
            .duplicate_receives = report.network.duplicate_receives,
            .restarts = report.network.restarts,
            .invariant_checks = report.network.invariant_checks,
        }, .{}, stdout);
        try stdout.writeByte('\n');
    } else {
        try stdout.print(
            "scenario={s} seed={} replicas={} actions={} rounds={} history={} scalars={} " ++
                "sent={} delivered={} dropped={} duplicates={} pending_receives={} restarts={} checks={} " ++
                "checksum={x} text=\"{s}\"\n",
            .{
                report.scenario.name(),
                report.seed,
                report.replicas,
                report.actions,
                report.settle_rounds,
                report.history_events,
                report.text_scalars,
                report.network.sent_changes,
                report.network.delivered_envelopes,
                report.network.dropped_changes,
                report.network.injected_duplicates,
                report.network.pending_receives,
                report.network.restarts,
                report.network.invariant_checks,
                report.checksum,
                report.final_text,
            },
        );
    }

    if (config.trace and report.trace.len != 0) {
        try stderr.print("lab: trace {s}\n{s}", .{ scenario.name(), report.trace });
    }
}

fn runSweep(
    io: Io,
    allocator: std.mem.Allocator,
    scenario: sim.Scenario,
    config: Config,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !void {
    const start = Io.Clock.awake.now(io).nanoseconds;
    var aggregate_checksum: u64 = 0;
    var max_history: usize = 0;
    var max_text_scalars: usize = 0;
    var total_sent: usize = 0;
    var total_delivered: usize = 0;
    var total_dropped: usize = 0;
    var total_duplicates: usize = 0;
    var total_pending: usize = 0;
    var total_restarts: usize = 0;
    var total_invariant_checks: usize = 0;
    var failure_trace: std.ArrayList(u8) = .empty;
    defer failure_trace.deinit(allocator);

    try stderr.print(
        "lab-fuzz: scenario={s} seeds={} first_seed={} replicas={} actions={}\n",
        .{ scenario.name(), config.sweep, config.options.seed, config.options.replicas, config.options.actions },
    );
    try stderr.flush();

    for (0..config.sweep) |case_index| {
        var options = config.options;
        options.seed +%= @intCast(case_index);
        options.capture_trace = false;

        var report = sim.runScenarioCapturingFailure(
            allocator,
            scenario,
            options,
            &failure_trace,
        ) catch |err| {
            try printFailure(stderr, scenario, config, options.seed, err, failure_trace.items);
            try stderr.flush();
            return err;
        };

        var checksum_input: [16]u8 = undefined;
        std.mem.writeInt(u64, checksum_input[0..8], report.seed, .little);
        std.mem.writeInt(u64, checksum_input[8..16], report.checksum, .little);
        aggregate_checksum = std.hash.Wyhash.hash(aggregate_checksum, &checksum_input);
        max_history = @max(max_history, report.history_events);
        max_text_scalars = @max(max_text_scalars, report.text_scalars);
        total_sent +%= report.network.sent_changes;
        total_delivered +%= report.network.delivered_envelopes;
        total_dropped +%= report.network.dropped_changes;
        total_duplicates +%= report.network.injected_duplicates;
        total_pending +%= report.network.pending_receives;
        total_restarts +%= report.network.restarts;
        total_invariant_checks +%= report.network.invariant_checks;
        report.deinit();

        const completed = case_index + 1;
        if (config.progress_every != 0 and
            (completed % config.progress_every == 0 or completed == config.sweep))
        {
            const elapsed = Io.Clock.awake.now(io).nanoseconds - start;
            try stderr.print(
                "lab-fuzz: passed {}/{} last_seed={} elapsed_ns={}\n",
                .{ completed, config.sweep, options.seed, elapsed },
            );
            try stderr.flush();
        }
    }

    const elapsed = Io.Clock.awake.now(io).nanoseconds - start;
    if (config.json) {
        try std.json.Stringify.value(.{
            .kind = "seed_sweep",
            .scenario = scenario.name(),
            .first_seed = config.options.seed,
            .seeds_passed = config.sweep,
            .replicas = config.options.replicas,
            .actions_per_seed = config.options.actions,
            .elapsed_ns = elapsed,
            .aggregate_checksum = aggregate_checksum,
            .max_history_events = max_history,
            .max_text_scalars = max_text_scalars,
            .total_sent_changes = total_sent,
            .total_delivered_envelopes = total_delivered,
            .total_dropped_changes = total_dropped,
            .total_injected_duplicates = total_duplicates,
            .total_pending_receives = total_pending,
            .total_restarts = total_restarts,
            .total_invariant_checks = total_invariant_checks,
        }, .{}, stdout);
        try stdout.writeByte('\n');
    } else {
        try stdout.print(
            "seed_sweep scenario={s} first_seed={} passed={} replicas={} actions_per_seed={} " ++
                "elapsed_ns={} aggregate_checksum={x} max_history={} max_scalars={} " ++
                "sent={} delivered={} dropped={} duplicates={} pending_receives={} restarts={} checks={}\n",
            .{
                scenario.name(),
                config.options.seed,
                config.sweep,
                config.options.replicas,
                config.options.actions,
                elapsed,
                aggregate_checksum,
                max_history,
                max_text_scalars,
                total_sent,
                total_delivered,
                total_dropped,
                total_duplicates,
                total_pending,
                total_restarts,
                total_invariant_checks,
            },
        );
    }
}

fn printFailure(
    stderr: *Io.Writer,
    scenario: sim.Scenario,
    config: Config,
    seed: u64,
    err: anyerror,
    trace: []const u8,
) !void {
    try stderr.print(
        "lab: FAILURE scenario={s} seed={} error={s}\n" ++
            "reproduce: zig build lab -- --scenario {s} --seed {} --replicas {} " ++
            "--actions {} --batch {} --rounds {} --drop {} --duplicate {} " ++
            "--max-delay {} --ordering {s} --trace\n",
        .{
            scenario.name(),
            seed,
            @errorName(err),
            scenario.name(),
            seed,
            config.options.replicas,
            config.options.actions,
            config.options.batch_limit,
            config.options.settle_rounds,
            config.options.faults.drop_percent,
            config.options.faults.duplicate_percent,
            config.options.faults.max_delay,
            @tagName(config.options.ordering),
        },
    );
    if (trace.len != 0) try stderr.print("lab: failing trace\n{s}", .{trace});
}

fn parseArgs(args: []const []const u8) !Config {
    var config = Config{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            config.help = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            config.json = true;
        } else if (std.mem.eql(u8, arg, "--trace")) {
            config.trace = true;
        } else if (std.mem.eql(u8, arg, "--sweep")) {
            config.sweep = try parseUnsigned(usize, try nextValue(args, &i));
        } else if (std.mem.eql(u8, arg, "--progress")) {
            config.progress_every = try parseUnsigned(usize, try nextValue(args, &i));
        } else if (std.mem.eql(u8, arg, "--scenario")) {
            const value = try nextValue(args, &i);
            config.scenario = if (std.mem.eql(u8, value, "all")) null else try sim.Scenario.parse(value);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            config.options.seed = try parseUnsigned(u64, try nextValue(args, &i));
        } else if (std.mem.eql(u8, arg, "--replicas")) {
            config.options.replicas = try parseUnsigned(usize, try nextValue(args, &i));
        } else if (std.mem.eql(u8, arg, "--actions")) {
            config.options.actions = try parseUnsigned(usize, try nextValue(args, &i));
        } else if (std.mem.eql(u8, arg, "--batch")) {
            config.options.batch_limit = try parseUnsigned(usize, try nextValue(args, &i));
        } else if (std.mem.eql(u8, arg, "--rounds")) {
            config.options.settle_rounds = try parseUnsigned(usize, try nextValue(args, &i));
        } else if (std.mem.eql(u8, arg, "--drop")) {
            config.options.faults.drop_percent = try parseUnsigned(u8, try nextValue(args, &i));
        } else if (std.mem.eql(u8, arg, "--duplicate")) {
            config.options.faults.duplicate_percent = try parseUnsigned(u8, try nextValue(args, &i));
        } else if (std.mem.eql(u8, arg, "--max-delay")) {
            config.options.faults.max_delay = try parseUnsigned(u32, try nextValue(args, &i));
        } else if (std.mem.eql(u8, arg, "--ordering")) {
            const value = try nextValue(args, &i);
            if (std.mem.eql(u8, value, "fugue")) {
                config.options.ordering = .fugue;
            } else if (std.mem.eql(u8, value, "fugue-max") or std.mem.eql(u8, value, "fugue_max")) {
                config.options.ordering = .fugue_max;
            } else {
                return CliError.InvalidArgument;
            }
        } else {
            return CliError.InvalidArgument;
        }
    }

    if (config.sweep == 0 or
        config.options.replicas < 2 or
        config.options.batch_limit == 0 or
        config.options.settle_rounds == 0 or
        config.options.faults.drop_percent > 100 or
        config.options.faults.duplicate_percent > 100)
    {
        return CliError.InvalidArgument;
    }
    return config;
}

fn nextValue(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return CliError.InvalidArgument;
    return args[index.*];
}

fn parseUnsigned(comptime T: type, value: []const u8) !T {
    return std.fmt.parseUnsigned(T, value, 0) catch return CliError.InvalidArgument;
}

fn printUsage(writer: *Io.Writer) !void {
    try writer.print(
        "usage: crdt-lab [options]\n" ++
            "  --scenario offline|partition|reorder|restart|random|all\n" ++
            "  --seed N          deterministic seed (default: 0xc0ffee)\n" ++
            "  --replicas N      random/partition replica count (default: 3)\n" ++
            "  --actions N       random scenario actions (default: 48)\n" ++
            "  --batch N         maximum changes per sync attempt (default: 16)\n" ++
            "  --rounds N        reliable settle-round limit (default: 128)\n" ++
            "  --drop N          transport drop percentage (default: 10)\n" ++
            "  --duplicate N     duplicate percentage (default: 15)\n" ++
            "  --max-delay N     maximum logical delivery delay (default: 8)\n" ++
            "  --ordering fugue|fugue-max\n" ++
            "  --sweep N         run N consecutive seeds (defaults to random)\n" ++
            "  --progress N      report every N completed seeds; 0 disables\n" ++
            "  --trace           write the deterministic event trace to stderr\n" ++
            "  --json            write one JSON object per scenario to stdout\n" ++
            "  --help            show this help\n",
        .{},
    );
}
