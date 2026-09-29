// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("wasapi", .{
        .root_source_file = b.path("src/wasapi.zig"),
        .target = target,
        .optimize = optimize,
    });
    configure(b, mod);

    // The half of the library with no operating system in it. A second compile root
    // rather than a subset of the first, so that a non-Windows host has something real
    // to run -- and so that `check` can prove the purity claim rather than trusting it.
    const portable = b.addModule("wasapi-portable", .{
        .root_source_file = b.path("src/portable.zig"),
        .target = target,
        .optimize = optimize,
    });

    // A minimal WAV writer, for the recording examples. Deliberately not part of the
    // library: a file format is not audio plumbing, and every consumer of `wasapi` would
    // otherwise carry it.
    const wav = b.addModule("wav", .{
        .root_source_file = b.path("tools/wav.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run tests");

    // The operating-system-independent suite: the ring buffer, the channel permutations,
    // the byte-exact format headers, the sample converters, the clock arithmetic, the
    // statistics handoff and the wait loop. Runs on any host.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .name = "portable-tests",
        .root_module = portable,
    })).step);

    if (target.result.os.tag == .windows) {
        // Everything above plus the COM half, which needs Windows to run at all.
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{
            .name = "unit-tests",
            .root_module = mod,
        })).step);

        // The end-to-end test: play a tone, record it back through a loopback capture,
        // and check the pitch. Needs real audio hardware and reports `SkipZigTest`
        // without it, so it lives outside `src` where a reader looking for unit tests
        // will not mistake it for one.
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{
            .name = "loopback-tests",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/loopback.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "wasapi", .module = mod }},
            }),
        })).step);
    }

    // The WAV writer has tests of its own -- the offset arithmetic -- and without this
    // they would never run.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = wav })).step);

    // The fuzz targets, against the portable half -- the only part of this library that
    // parses bytes it did not write, plus the pure code whose invariants are cheap to
    // state. Runs on any host, and runs as an ordinary test suite without `--fuzz`: each
    // target still gets its corpus and a short random run, which is worth having in CI
    // even when nobody is fuzzing.
    const fuzz_filter = b.option(
        []const u8,
        "fuzz-filter",
        "Run only the fuzz target whose name matches",
    );
    const fuzz_tests = b.addTest(.{
        .name = "fuzz-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "wasapi-portable", .module = portable }},
        }),
        .filters = if (fuzz_filter) |f| &.{f} else &.{},
    });
    test_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    const fuzz_step = b.step("fuzz", "The fuzz targets: add --fuzz to fuzz them");
    fuzz_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    const examples = [_]struct { name: []const u8, desc: []const u8 }{
        .{ .name = "devices", .desc = "List the endpoints, their volumes, and what is playing" },
        .{ .name = "tone", .desc = "Play a test tone (push API): pass a frequency and a duration" },
        .{ .name = "callback", .desc = "Play a chord (pull API) from a process callback" },
        .{ .name = "record", .desc = "Record the default microphone into a WAV file" },
        .{ .name = "loopback", .desc = "Record what this machine is playing into a WAV file" },
    };

    for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = b.fmt("wasapi-{s}", .{example.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example.name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "wasapi", .module = mod },
                    .{ .name = "wav", .module = wav },
                },
            }),
        });
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        run_cmd.stdio = .inherit;
        if (b.args) |args| run_cmd.addArgs(args);
        const run_step = b.step(b.fmt("run-{s}", .{example.name}), example.desc);
        run_step.dependOn(&run_cmd.step);

        // Each example's own module is tested too. They carry the worked code a reader
        // copies, and without this an example could stop compiling and `zig build test`
        // would not notice.
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{
            .root_module = exe.root_module,
        })).step);
    }

    // --- documentation ---

    const docs_port = b.option(
        u16,
        "docs-port",
        "Port for `zig build docs-serve` (default 8000)",
    ) orelse 8000;

    const docs_obj = b.addObject(.{ .name = "wasapi", .root_module = mod });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Build the API documentation into zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    const docs_server = b.addExecutable(.{
        .name = "docs-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/docs_server.zig"),
            // Always built for the machine running the build, never for whatever
            // -Dtarget the library is being built for.
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const run_docs_server = b.addRunArtifact(docs_server);
    run_docs_server.step.dependOn(&install_docs.step);
    run_docs_server.addArg(b.getInstallPath(.prefix, "docs"));
    run_docs_server.addArg(b.fmt("{d}", .{docs_port}));
    // The server runs until interrupted, so its output has to reach the terminal rather
    // than being captured by the build runner.
    run_docs_server.stdio = .inherit;

    const docs_serve_step = b.step("docs-serve", "Serve the API documentation over HTTP");
    docs_serve_step.dependOn(&run_docs_server.step);

    // The server has tests of its own; without this they would never run.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_module = docs_server.root_module,
    })).step);

    // `pkg_hash` is empty for the root package and is the hash of the package otherwise,
    // which is exactly the distinction wanted: a dependent should not pay for this
    // repository's own cross-compilation checks.
    if (b.pkg_hash.len == 0) addCheckStep(b, optimize);
}

/// Everything about the module that depends on which operating system it is being built
/// for.
///
/// Called once for the published module and once per target in the `check` step, so that
/// what CI compiles and what a dependent compiles cannot drift apart.
fn configure(b: *std.Build, mod: *std.Build.Module) void {
    switch (mod.resolved_target.?.result.os.tag) {
        .windows => {
            // Not optional. The bindings reach `ole32` and `avrt` through
            // `pub extern "ole32" fn` declarations, and a build that does not link --
            // which is exactly what `zig build check` does -- refuses those without it:
            // "dependency on dynamic library 'ole32' requires enabling Position
            // Independent Code".
            mod.pic = true;
            if (b.lazyDependency("win32", .{})) |dep| {
                mod.addImport("win32", dep.module("win32"));
            }
        },
        // Every other target reaches the `@compileError` in `src/support.zig` rather than
        // a missing import, so there is nothing to configure.
        else => {},
    }
}

/// The targets `zig build check` compiles for.
///
/// Both Windows architectures, and one non-Windows target for `src/portable.zig` -- which
/// is what turns "no file in the portable half imports `win32`" from a convention into a
/// compile error.
///
/// The GNU ABI rather than MSVC: the MSVC ABI wants the Windows SDK's import libraries,
/// while the GNU one uses the `.def` files Zig bundles, so it cross-compiles from
/// anywhere.
const checked_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu },
};

fn addCheckStep(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    const check_step = b.step("check", "Compile for every supported target without running it");

    const check_windows = b.option(
        bool,
        "check-windows",
        "Include the Windows targets in `zig build check` (fetches the Win32 bindings)",
    ) orelse true;

    for (checked_targets) |query| {
        if (query.os_tag == .windows and !check_windows) continue;
        const resolved = b.resolveTargetQuery(query);

        const mod = b.createModule(.{
            .root_source_file = b.path("src/wasapi.zig"),
            .target = resolved,
            .optimize = optimize,
        });
        configure(b, mod);

        // Rooted at `tools/check_root.zig` rather than at the library, because an object
        // built from a library that exports no symbols analyses almost nothing. See that
        // file.
        const root = b.createModule(.{
            .root_source_file = b.path("tools/check_root.zig"),
            .target = resolved,
            .optimize = optimize,
            .imports = &.{.{ .name = "wasapi", .module = mod }},
        });

        check_step.dependOn(&b.addObject(.{
            .name = b.fmt("wasapi-{t}-{t}", .{ query.cpu_arch.?, query.os_tag.? }),
            .root_module = root,
        }).step);
    }

    // The portable half, compiled for a system that has no WASAPI at all. If anything in
    // it ever reaches for `win32`, this is what stops compiling.
    check_step.dependOn(&b.addObject(.{
        .name = "wasapi-portable-linux",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/portable.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
                .os_tag = .linux,
                .abi = .gnu,
            }),
            .optimize = optimize,
        }),
    }).step);
}
