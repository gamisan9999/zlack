const std = @import("std");
const App = @import("app.zig").App;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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
