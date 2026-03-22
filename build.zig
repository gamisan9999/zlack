const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const websocket_dep = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });

    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zlack",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "websocket", .module = websocket_dep.module("websocket") },
                .{ .name = "vaxis", .module = vaxis_dep.module("vaxis") },
            },
            .link_libc = true,
        }),
    });
    linkNativeDeps(b, exe);
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run zlack");
    run_step.dependOn(&run_cmd.step);

    // Test step — モジュールごとに addTest を追加し、全テストを実行する
    const test_step = b.step("test", "Run unit tests");

    const test_modules = [_][]const u8{
        "src/main.zig",
        "src/store/db.zig",
        "src/slack/types.zig",
        "src/slack/pagination.zig",
        "src/slack/api.zig",
        "src/platform/keychain.zig",
        "src/slack/auth.zig",
        "src/slack/socket.zig",
        "src/store/cache.zig",
    };

    for (test_modules) |mod| {
        const unit_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(mod),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "websocket", .module = websocket_dep.module("websocket") },
                    .{ .name = "vaxis", .module = vaxis_dep.module("vaxis") },
                },
                .link_libc = true,
            }),
        });
        linkNativeDeps(b, unit_test);
        const run_test = b.addRunArtifact(unit_test);
        test_step.dependOn(&run_test.step);
    }
}

/// Link SQLite and macOS Security framework to the given compile step.
fn linkNativeDeps(b: *std.Build, step: *std.Build.Step.Compile) void {
    step.linkSystemLibrary("sqlite3");
    if (b.graph.host.result.os.tag == .macos) {
        step.addFrameworkPath(.{ .cwd_relative = "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks" });
    }
    step.linkFramework("Security");
    step.linkFramework("CoreFoundation");
}
