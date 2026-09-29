// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! List every audio endpoint, its volume, and what each program is playing to it.
//!
//! Roughly what the Windows Volume Mixer shows, from the same interfaces it uses.
//!
//! ```console
//! $ zig build run-devices
//! Render endpoints
//!   * Speakers (High Definition Audio Device)          active    38%
//!       {0.0.0.00000000}.{ea2f2b17-d6b0-4ebb-a2f5-d773e023a687}
//!       48000 Hz, 2 ch, f32, mask 0x3
//!       - pid 24180  active  61%
//!       - System Sounds  inactive  100%
//!
//! Capture endpoints
//!   * Line In (High Definition Audio Device)           active   100%
//! ```
//!
//! Pass `--set <substring> <percent>` to change an endpoint's volume, which is the
//! same thing as moving the system tray slider.

const std = @import("std");
const wasapi = @import("wasapi");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var session: wasapi.Session = try .open(io, .{});
    defer session.close(io);

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len >= 4 and std.mem.eql(u8, args[1], "--set")) {
        try setVolume(&session, stdout, args[2], args[3]);
        return;
    }

    for ([_]wasapi.Flow{ .render, .capture }) |flow| {
        try stdout.print("\n{s} endpoints\n", .{switch (flow) {
            .render => "Render",
            .capture => "Capture",
        }});

        // The default's id, so the listing can mark it rather than printing it twice.
        var default_id_buf: [wasapi.Endpoint.max_id_len]u8 = undefined;
        const default_id: ?[]const u8 = blk: {
            const maybe = switch (flow) {
                .render => try session.defaultSink(),
                .capture => try session.defaultSource(),
            };
            var device = maybe orelse break :blk null;
            defer device.deinit();
            break :blk try device.id(&default_id_buf);
        };

        var endpoints = try session.endpoints(flow, wasapi.com.enumerator.state_mask_all);
        defer endpoints.deinit();

        if (endpoints.count == 0) try stdout.print("  (none)\n", .{});

        while (try endpoints.next()) |endpoint| {
            var device = endpoint;
            defer device.deinit();
            try printEndpoint(&session, stdout, device, default_id);
        }
    }
}

fn printEndpoint(
    session: *wasapi.Session,
    stdout: *std.Io.Writer,
    device: wasapi.Endpoint,
    default_id: ?[]const u8,
) !void {
    var id_buf: [wasapi.Endpoint.max_id_len]u8 = undefined;
    const id = try device.id(&id_buf);

    var name_buf: [wasapi.Endpoint.max_name_len]u8 = undefined;
    const name = try device.label(&name_buf);

    const state = try device.state();
    const is_default = if (default_id) |d| std.mem.eql(u8, d, id) else false;

    // A disabled or unplugged endpoint has no volume to read and nothing playing to
    // it, so asking would just produce errors.
    if (!state.usable()) {
        try stdout.print("  {s} {s: <48} {t}\n", .{
            if (is_default) "*" else " ",
            name,
            state,
        });
        return;
    }

    const volume = try session.volume(device);
    try stdout.print("  {s} {s: <48} {t: <10} {f}\n", .{
        if (is_default) "*" else " ",
        name,
        state,
        volume,
    });
    try stdout.print("      {s}\n", .{id});

    try printAppSessions(session, stdout, device);
}

fn printAppSessions(
    session: *wasapi.Session,
    stdout: *std.Io.Writer,
    device: wasapi.Endpoint,
) !void {
    var sessions = session.appSessions(device) catch |err| {
        // A capture endpoint, or one whose session manager will not activate. Worth
        // saying rather than pretending nothing is playing to it.
        try stdout.print("      (no session list: {t})\n", .{err});
        return;
    };
    defer sessions.deinit();

    while (try sessions.next()) |app| {
        var entry = app;
        defer entry.deinit();

        var name_buf: [wasapi.AppSession.max_name_len]u8 = undefined;
        const label = if (entry.isSystemSounds())
            "System Sounds"
        else if (try entry.displayName(&name_buf)) |name|
            name
        else
            // Most programs never set a display name, so this is the common case --
            // the Volume Mixer looks the process up instead, which needs privileges
            // this example does not want.
            try std.fmt.bufPrint(&name_buf, "pid {d}", .{try entry.processId()});

        try stdout.print("      - {s: <32} {t: <9} {d:.0}%{s}\n", .{
            label,
            try entry.state(),
            (try entry.level()) * 100,
            if (try entry.muted()) " muted" else "",
        });
    }
}

fn setVolume(
    session: *wasapi.Session,
    stdout: *std.Io.Writer,
    wanted: []const u8,
    percent_text: []const u8,
) !void {
    const percent = std.fmt.parseFloat(f32, percent_text) catch {
        try stdout.print("\"{s}\" is not a percentage\n", .{percent_text});
        return;
    };

    var endpoints = try session.sinks();
    defer endpoints.deinit();

    while (try endpoints.next()) |endpoint| {
        var device = endpoint;
        defer device.deinit();

        var name_buf: [wasapi.Endpoint.max_name_len]u8 = undefined;
        const name = try device.label(&name_buf);
        if (std.ascii.indexOfIgnoreCase(name, wanted) == null) continue;

        try session.setVolume(device, percent / 100);
        try stdout.print("{s} is now at {f}\n", .{ name, try session.volume(device) });
        return;
    }

    try stdout.print("no output endpoint's name contains \"{s}\"\n", .{wanted});
}
