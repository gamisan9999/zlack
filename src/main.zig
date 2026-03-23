const std = @import("std");
const App = @import("app.zig").App;

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
    for (args[1..]) |arg| {
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
                \\  --version, -v    Show version
                \\  --help, -h       Show this help
                \\  --reconfigure    Re-enter tokens (ignore keychain)
                \\
            ) catch {};
            return;
        }
        if (std.mem.eql(u8, arg, "--reconfigure")) {
            reconfigure = true;
        }
    }

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
