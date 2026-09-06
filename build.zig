const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_module = b.addModule("crdt_tests", .{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_tests = b.addRunArtifact(tests);
    const exercise_check_step = b.step("exercise-check", "Compile the historical learning exercises");
    exercise_check_step.dependOn(&tests.step);
    const exercise_test_step = b.step("exercise-test", "Run the historical learning exercises");
    exercise_test_step.dependOn(&run_tests.step);

    const check_step = b.step("check", "Compile the maintained native test graph without running it");
    const test_step = b.step("test", "Run the maintained native test graph");

    // The public library module is rooted at the implementation's stable
    // facade.  Keep the historical module tests above, then compile the
    // facade and its conformance fixtures as separate test artifacts.
    const library_module = b.addModule("collab", .{
        .root_source_file = b.path("src/replica.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Feed the checked-in Eg-walker corpus to the conformance test through a
    // build option.  The source file has an empty fallback so ordinary local
    // compilation remains usable when the corpus is unavailable.
    const external_corpus = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        "research/eg-walker-reference/testdata/conformance.json",
        b.allocator,
        .limited(8 * 1024 * 1024),
    ) catch "";
    const external_options = b.addOptions();
    const full_external = b.option(bool, "full-external", "Replay every trace in the checked-in external corpus") orelse false;
    const external_trace_index = b.option(usize, "trace-index", "Replay one external corpus trace by index") orelse std.math.maxInt(usize);
    external_options.addOption(bool, "available", external_corpus.len != 0);
    external_options.addOption(bool, "full", full_external);
    external_options.addOption(usize, "trace_index", external_trace_index);
    external_options.addOption([]const u8, "json", external_corpus);

    const library_tests = b.addTest(.{
        .root_module = library_module,
    });
    const run_library_tests = b.addRunArtifact(library_tests);
    const library_test_step = b.step("library-test", "Run the native library tests");
    library_test_step.dependOn(&run_library_tests.step);

    const conformance_module = b.addModule("collab_conformance", .{
        .root_source_file = b.path("src/conformance.zig"),
        .target = target,
        .optimize = optimize,
    });
    conformance_module.addOptions("external_conformance_options.zig", external_options);
    const conformance_tests = b.addTest(.{
        .root_module = conformance_module,
    });
    const run_conformance_tests = b.addRunArtifact(conformance_tests);
    const conformance_test_step = b.step("conformance-test", "Run sequence conformance fixtures");
    conformance_test_step.dependOn(&run_conformance_tests.step);

    // `test` and `check` cover every native test artifact, so a normal build
    // cannot accidentally omit the facade or conformance suite.
    check_step.dependOn(&library_tests.step);
    check_step.dependOn(&conformance_tests.step);
    test_step.dependOn(&run_library_tests.step);
    test_step.dependOn(&run_conformance_tests.step);

    const benchmark_module = b.addModule("crdt_bench", .{
        .root_source_file = b.path("bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    benchmark_module.addImport("collab", library_module);
    const benchmark = b.addExecutable(.{
        .name = "crdt-bench",
        .root_module = benchmark_module,
    });
    const install_benchmark = b.addInstallArtifact(benchmark, .{});
    const benchmark_step = b.step("bench", "Run the native benchmark and allocation harness");
    benchmark_step.dependOn(&install_benchmark.step);
    const run_benchmark = b.addRunArtifact(benchmark);
    run_benchmark.step.dependOn(&install_benchmark.step);
    if (b.args) |args| run_benchmark.addArgs(args);
    benchmark_step.dependOn(&run_benchmark.step);

    // Keep the old step name as a harmless compatibility alias while callers
    // migrate to `zig build bench`.
    const benchmark_alias_step = b.step("reference-bench", "Compatibility alias for the benchmark step");
    benchmark_alias_step.dependOn(&run_benchmark.step);

    const lab_module = b.addModule("crdt_lab", .{
        .root_source_file = b.path("lab/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    lab_module.addImport("collab", library_module);
    const lab_executable = b.addExecutable(.{
        .name = "crdt-lab",
        .root_module = lab_module,
    });
    const install_lab = b.addInstallArtifact(lab_executable, .{});
    const run_lab = b.addRunArtifact(lab_executable);
    run_lab.step.dependOn(&install_lab.step);
    if (b.args) |args| run_lab.addArgs(args);
    const lab_step = b.step("lab", "Run the deterministic distributed-systems lab");
    lab_step.dependOn(&install_lab.step);
    lab_step.dependOn(&run_lab.step);

    const run_lab_fuzz = b.addRunArtifact(lab_executable);
    run_lab_fuzz.step.dependOn(&install_lab.step);
    run_lab_fuzz.addArgs(&.{
        "--scenario",
        "random",
        "--sweep",
        "10000",
        "--replicas",
        "4",
        "--actions",
        "96",
        "--batch",
        "8",
        "--drop",
        "20",
        "--duplicate",
        "25",
        "--max-delay",
        "16",
        "--progress",
        "250",
    });
    if (b.args) |args| run_lab_fuzz.addArgs(args);
    const lab_fuzz_step = b.step("lab-fuzz", "Sweep deterministic hostile network schedules");
    lab_fuzz_step.dependOn(&install_lab.step);
    lab_fuzz_step.dependOn(&run_lab_fuzz.step);

    const lab_test_module = b.addModule("crdt_lab_tests", .{
        .root_source_file = b.path("lab/simulator.zig"),
        .target = target,
        .optimize = optimize,
    });
    lab_test_module.addImport("collab", library_module);
    const lab_tests = b.addTest(.{
        .root_module = lab_test_module,
    });
    const run_lab_tests = b.addRunArtifact(lab_tests);
    const lab_test_step = b.step("lab-test", "Run deterministic network simulation scenarios");
    lab_test_step.dependOn(&run_lab_tests.step);
    check_step.dependOn(&lab_executable.step);
    check_step.dependOn(&lab_tests.step);
    test_step.dependOn(&run_lab_tests.step);
}
