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
        var stderr_buf: [256]u8 = undefined;
        var stderr_w = std.fs.File.stderr().writer(&stderr_buf);
        stderr_w.interface.print("zlack error: {}\n", .{err}) catch {};
        std.process.exit(1);
    };
}
