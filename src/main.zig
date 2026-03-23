const std = @import("std");
const App = @import("app.zig").App;
const TailRunner = @import("tail.zig").TailRunner;

const version = "0.1.1";
const log_dir = ".local/share/zlack";
const log_filename = "zlack.log";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse arguments (before log redirect so --version/--help print to stdout)
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var reconfigure = false;
    var tail_channels: std.ArrayListUnmanaged([]const u8) = .{};
    defer tail_channels.deinit(allocator);
    var tail_dir: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            const stdout = std.fs.File.stdout();
            _ = stdout.write("zlack " ++ version ++ "\n") catch {};
            return;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            const stdout = std.fs.File.stdout();
            _ = stdout.write(
                \\zlack - A lightweight Slack client for the terminal
                \\
                \\Usage: zlack [OPTIONS]
                \\
                \\Options:
                \\  --version, -v        Show version
                \\  --help, -h           Show this help
                \\  --reconfigure        Re-enter tokens (ignore keychain)
                \\  --tail <channels>    Tail mode: print messages to stdout
                \\                       Comma-separated channel names
                \\  --tail-dir <path>    Write each channel to a separate .log file
                \\
                \\Examples:
                \\  zlack                          Start TUI mode
                \\  zlack --tail general           Tail #general to stdout
                \\  zlack --tail general,random    Tail multiple channels
                \\  zlack --tail general | grep deploy
                \\  zlack --tail general,random --tail-dir /tmp/logs/
                \\
            ) catch {};
            return;
        }
        if (std.mem.eql(u8, arg, "--reconfigure")) {
            reconfigure = true;
        }
        if (std.mem.eql(u8, arg, "--tail")) {
            if (i + 1 < args.len) {
                i += 1;
                // Split comma-separated channel names
                var it = std.mem.splitScalar(u8, args[i], ',');
                while (it.next()) |name| {
                    if (name.len > 0) {
                        tail_channels.append(allocator, name) catch {};
                    }
                }
            }
        }
        if (std.mem.eql(u8, arg, "--tail-dir")) {
            if (i + 1 < args.len) {
                i += 1;
                tail_dir = args[i];
            }
        }
    }

    // --- Tail mode ---
    if (tail_channels.items.len > 0) {
        var runner = TailRunner.init(allocator, tail_channels.items, tail_dir);
        defer runner.deinit();
        runner.run() catch |err| {
            const msg = @errorName(err);
            const stderr = std.fs.File.stderr();
            _ = stderr.write("zlack-tail error: ") catch {};
            _ = stderr.write(msg) catch {};
            _ = stderr.write("\n") catch {};
            std.process.exit(1);
        };
        return;
    }

    // --- TUI mode ---
    // Redirect stderr to log file
    const log_path = setupLogFile() catch null;
    defer if (log_path) |path| {
        const stdout = std.fs.File.stdout();
        _ = stdout.write("Log saved to: ") catch {};
        _ = stdout.write(path) catch {};
        _ = stdout.write("\nYou can remove it if not needed.\n") catch {};
    };

    var app = try App.init(allocator, reconfigure);
    defer app.deinit();

    app.run() catch |err| {
        const msg = @errorName(err);
        const stderr = std.fs.File.stderr();
        _ = stderr.write("zlack error: ") catch {};
        _ = stderr.write(msg) catch {};
        _ = stderr.write("\n") catch {};
        std.process.exit(1);
    };
}

/// Create log directory and redirect stderr to log file.
fn setupLogFile() ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;

    var dir_buf: [512]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ home, log_dir }) catch return error.PathTooLong;
    std.fs.cwd().makePath(dir_path) catch {};

    const path = std.fmt.bufPrint(&log_path_buf, "{s}/{s}/{s}", .{ home, log_dir, log_filename }) catch return error.PathTooLong;
    const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return error.LogOpenFailed;

    std.posix.dup2(file.handle, std.posix.STDERR_FILENO) catch {
        file.close();
        return error.Dup2Failed;
    };
    file.close();
    return path;
}

var log_path_buf: [512]u8 = undefined;
