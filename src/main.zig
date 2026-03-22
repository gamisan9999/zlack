const std = @import("std");
const App = @import("app.zig").App;

const log_dir = ".local/share/zlack";
const log_filename = "zlack.log";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Redirect stderr to log file
    const log_path = setupLogFile() catch null;
    defer if (log_path) |path| {
        // Restore stderr and print log location
        const stdout = std.fs.File.stdout();
        _ = stdout.write("Log saved to: ") catch {};
        _ = stdout.write(path) catch {};
        _ = stdout.write("\nYou can remove it if not needed.\n") catch {};
    };

    // Parse arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const reconfigure = for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--reconfigure")) break true;
    } else false;

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
/// Returns the full path string on success (static buffer).
fn setupLogFile() ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;

    // Build directory path
    var dir_buf: [512]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ home, log_dir }) catch return error.PathTooLong;

    // Ensure directory exists
    std.fs.cwd().makePath(dir_path) catch {};

    // Build file path
    const path = std.fmt.bufPrint(&log_path_buf, "{s}/{s}/{s}", .{ home, log_dir, log_filename }) catch return error.PathTooLong;

    // Open log file (truncate on each launch)
    const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return error.LogOpenFailed;

    // Redirect stderr fd to the log file
    std.posix.dup2(file.handle, std.posix.STDERR_FILENO) catch {
        file.close();
        return error.Dup2Failed;
    };
    file.close(); // fd is now duplicated to stderr

    return path;
}

var log_path_buf: [512]u8 = undefined;
