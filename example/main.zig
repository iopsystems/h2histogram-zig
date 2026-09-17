const std = @import("std");
const h = @import("h2histogram");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var histogram = try h.Histogram.init(allocator, try h.Config.init(7, 64));
    defer histogram.deinit();

    try histogram.record(100, 1);
    try histogram.record(1000, 3);
    var report = try histogram.toCumulative(allocator);
    defer report.deinit();

    var output: [3]?h.Bucket = undefined;
    try report.percentilesInto(&.{ 0, 0.5, 1 }, &output);
    for (output) |item| if (item) |b| {
        std.debug.print("[{d}, {d}] count={d}\n", .{ b.start, b.end, b.count });
    };
}
