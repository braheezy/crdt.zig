# Collaborative text engine

This is the native collaborative text engine for the project.

Current status: the native implementation has a complete, correctness-focused
native mechanics baseline. Linear edits
use the cached text directly. Concurrent edits use Eg-walker's
prepare/effect retreat-and-advance model and now attempt a conservative
critical-version replay: the older prefix is replaced with local placeholder
records, only the suffix is walked, and the temporary merge state is discarded
after producing one text splice. If the inexpensive critical-cut proof or
placeholder mapping is inconclusive, the same operation is handled by the
exhaustive walker as a correctness fallback.

The current baseline also includes dependency-aware pending delivery,
idempotent/conflict-checked receives, indexed event and anchor lookup during
replay, causal `changesSince`, sparse per-actor `Have` summaries and
dependency-closed `changesForHave` batches, transactional arena-backed replay,
and a versioned varint/CRC save format that preserves pending changes, plus an
append-only `ChangeLog` with transactional replay, bounded frame admission,
and strict/recover torn-tail policies. The
steady state keeps rendered UTF-8 bytes rather than a persistent CRDT sequence.
The placeholder implementation is scalar-granular and deliberately
conservative; ranked trees, run-length encoding, and a benchmark-backed
critical-cut cache remain future performance work.

The mechanics gate and evidence are tracked in
`REFERENCE_COMPLETION.md`. The anchored ordering has an independent replay
oracle, generated multi-round DAGs, and a pinned comparison against all 1,000
traces in the checked-in Eg-walker/YjsMod corpus. The native default is
FugueMax; the corpus comparison explicitly selects plain Fugue because that is
the `rightParent` rule active in its source.

The primary public entry point is `Replica`. A
replica creates local edits, accepts remote changes, renders text, and exposes
the state needed for synchronization. `ChangeLog` is the small public
append/replay persistence façade; the causal history, sequence ordering, and
merge machinery remain internal modules.

Run the complete native suite with `zig build test`.

The optional Vaxis terminal client is enabled explicitly:

```sh
zig build client     # install zig-out/bin/crdt-client
zig build client-run # launch in the current terminal
```

Each client process owns one editable replica. Connect two processes with
`--listen IP:PORT` and `--connect IP:PORT`, using a separate `--session FILE`
for each. Changes synchronize automatically; Ctrl-O toggles networking,
Ctrl-S saves, and Ctrl-Q quits. Run `zig build client-test` for editor and TCP
integration tests. See `client/README.md` for LAN/Tailscale commands and limits.
These commands invoke the separate build in `client/`, which resolves Vaxis.
Normal library builds, tests, benchmarks, and lab runs do not invoke that build.

Initial public contract:

```text
Replica.init(allocator, actor)
Replica.initWithOrdering(allocator, actor, .fugue | .fugue_max)
Replica.deinit()
Replica.insert(index, utf8_text) -> ChangeId
Replica.delete(index, scalar_length) -> ChangeId
Replica.applyGroup(edits, allocator) -> owned ChangeBatch
Replica.receive(change) -> ReceiveResult
Replica.textView() -> borrowed UTF-8 bytes
Replica.text(allocator) -> owned UTF-8 bytes
Replica.historyCount() / pendingCount() / frontierView()
Replica.actorId() / orderingMode() / visibleScalarCount() / hasChange()
Replica.stats() -> ReplicaStats (zero-allocation diagnostics)
Replica.have() / changesForHave(have)
Have.encode() / Have.decode()
Replica.version() -> Version
Replica.changesSince(version) -> owned changes
Replica.save(allocator) -> owned bytes (snapshot format v2)
Replica.load(allocator, bytes) -> Replica
Replica.loadWithOptions(allocator, bytes, LoadOptions) -> Replica
LoadOptions.max_log_frames bounds one ChangeLog replay stream
ChangeLog.init(allocator)
ChangeLog.append(change) / appendBatch(changes) / appendSince(replica, version)
ChangeLog.replay(replica, ReplayOptions) -> ReplayResult
SyncCursor.init(peer_have)
SyncCursor.next(source, max_changes, allocator) -> ChangeBatch
SyncCursor.acknowledge(batch)
```

The current native milestone is a deterministic engine with versioned
snapshots and append-only logs: multiple replicas can edit offline, exchange
changes in any order (including duplicates), and converge. The exhaustive replay oracle remains isolated
behind the history/sequence boundary so the critical-version implementation
can be optimized or replaced without changing the public API.

Filesystem adapters and WASM bindings are later integration work. C ABI support
is deliberately deferred until the native API is stable.

The benchmark and allocation harness is `bench.zig`. Run
`zig build bench -Doptimize=ReleaseFast -- --scenario all --edits 64 --replicas 3 --batch 32 --repeat 3 --json`
and see `BENCHMARKS.md` for the workload definitions and output schema. The
harness checks convergence and persistence round trips while recording timing
and allocator counters; it is the baseline for later data structure changes.

The dependency-free distributed-systems lab is under `lab/`. Run
`zig build lab -- --scenario all` for offline, partition, reordered-delivery,
restart, and seeded-random scenarios. `zig build lab-test` runs its focused
integration suite. `zig build lab-fuzz -Doptimize=ReleaseFast` runs the heavier
10,000-seed stateful fault sweep with progress and exact failure reproduction.
See `LAB.md` for the network model, checked invariants, fault controls, and the
boundary between the CRDT core and an application transport.
