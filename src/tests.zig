const std = @import("std");
const h = @import("root.zig");
const a = std.testing.allocator;
test "geometry preserves boundaries and rejects impossible shapes" {
    const c = try h.Config.init(7, 64);
    try std.testing.expectEqual(@as(u32, 7424), c.total_buckets);
    try std.testing.expectEqual(@as(u32, 256), try c.index(257));
    try std.testing.expectEqual(@as(u64, 257), (try c.range(256)).end);
    try std.testing.expectEqual(std.math.maxInt(u64), (try c.range(7423)).end);
    try std.testing.expectError(error.InvalidConfig, h.Config.init(4, 4));
    try std.testing.expectError(error.Overflow, h.Config.init(31, 32));
}
test "record wrap lifecycle and transactional arithmetic" {
    const c = try h.Config.init(2, 4);
    var x = try h.Histogram.init(a, c);
    defer x.deinit();
    var y = try h.Histogram.init(a, c);
    defer y.deinit();
    try x.record(1, std.math.maxInt(u64));
    try x.record(1, 1);
    try std.testing.expectEqual(@as(u64, 0), try x.total());
    try x.record(2, 3);
    try x.snapshotInto(&y);
    try x.record(2, 1);
    try std.testing.expectEqual(@as(u64, 3), try y.total());
    try x.drainInto(&y);
    try std.testing.expectEqual(@as(u64, 0), try x.total());
    try std.testing.expectEqual(@as(u64, 4), try y.total());
    try x.record(1, std.math.maxInt(u64));
    try y.record(1, 1);
    try std.testing.expectError(error.Overflow, x.add(&y));
    try std.testing.expectEqual(@as(u64, 0), x.counts[2]);
    try std.testing.expectError(error.Overflow, h.Histogram.sum(a, &.{ &x, &y }));
    try std.testing.expectEqual(std.math.maxInt(u64), x.counts[1]);
    x.reset();
    y.reset();
    try x.record(0, 1);
    try y.record(0, 1);
    try x.record(3, std.math.maxInt(u64));
    try y.record(3, 1);
    try std.testing.expectError(error.Overflow, x.add(&y));
    try std.testing.expectEqual(@as(u64, 1), x.counts[0]);
}
test "native snapshots reports transforms and invalid zero entries" {
    const c = try h.Config.init(2, 8);
    var x = try h.Histogram.init(a, c);
    defer x.deinit();
    try x.record(1, 2);
    try x.record(200, 3);
    var s = try x.toSparse(a);
    defer s.deinit();
    var p = try s.toCumulative(a);
    defer p.deinit();
    try std.testing.expectEqual(@as(u64, 1), (try p.percentile(0)).?.start);
    try std.testing.expectEqual(@as(u64, 223), (try p.percentile(1)).?.end);
    try std.testing.expectEqual(@as(u64, 2), (try s.percentile(0.4)).?.count);
    var out: [2]?h.Bucket = .{ null, null };
    try std.testing.expectError(error.InvalidPercentile, p.percentilesInto(&.{ 0, std.math.nan(f64) }, &out));
    try std.testing.expect(out[0] == null);
    var d = try p.downsample(a, 1);
    defer d.deinit();
    try std.testing.expectEqual(@as(u64, 5), try d.total());
    var back = try p.toSparse(a);
    defer back.deinit();
    try std.testing.expectEqualSlices(h.Entry, s.entries, back.entries);
    var merged = try s.merge(a, &s);
    defer merged.deinit();
    try std.testing.expectEqual(@as(u64, 10), try merged.total());
    try std.testing.expect((try p.mean()).? > 100);
    try std.testing.expectError(error.InvalidShape, h.Sparse.init(a, c, &.{ .{ .index = 2, .count = 0 }, .{ .index = 1, .count = 1 } }));
    try std.testing.expectError(error.InvalidShape, h.Cumulative.init(a, c, &.{ .{ .index = 1, .count = 2 }, .{ .index = 2, .count = 1 } }));
}
test "reports reject total overflow and preserve exact endpoint ranks" {
    const c = try h.Config.init(0, 2);
    var s = try h.Sparse.init(a, c, &.{ .{ .index = 0, .count = std.math.maxInt(u64) - 1 }, .{ .index = 2, .count = 1 } });
    defer s.deinit();
    try std.testing.expectEqual(@as(u64, 3), (try s.percentile(1)).?.end);
    var x = try h.Histogram.init(a, c);
    defer x.deinit();
    try x.record(0, std.math.maxInt(u64));
    try x.record(1, 1);
    try std.testing.expectError(error.Overflow, x.percentile(0));
}
fn allocationScenario(allocator: std.mem.Allocator) !void {
    var x = try h.Histogram.init(allocator, try h.Config.init(2, 8));
    defer x.deinit();
    try x.record(200, 3);
    var s = try x.toSparse(allocator);
    defer s.deinit();
    var p = try s.toCumulative(allocator);
    defer p.deinit();
    var m = try p.merge(allocator, &p);
    defer m.deinit();
    var d = try m.downsample(allocator, 1);
    defer d.deinit();
    var imported = try h.Histogram.fromCounts(allocator, x.config, x.counts);
    defer imported.deinit();
    var sum = try h.Histogram.sum(allocator, &.{ &x, &imported });
    defer sum.deinit();
    var dense_down = try sum.downsample(allocator, 1);
    defer dense_down.deinit();
    var sparse_import = try h.Sparse.init(allocator, s.config, s.entries);
    defer sparse_import.deinit();
    var sparse_merge = try s.merge(allocator, &sparse_import);
    defer sparse_merge.deinit();
    var sparse_down = try sparse_merge.downsample(allocator, 1);
    defer sparse_down.deinit();
    var prefix_import = try h.Cumulative.init(allocator, p.config, p.entries);
    defer prefix_import.deinit();
    var decumulated = try prefix_import.toSparse(allocator);
    defer decumulated.deinit();
}
test "every allocation failure cleans owned partial results" {
    try std.testing.checkAllAllocationFailures(a, allocationScenario, .{});
}
test "Rust checked independent integer fixtures" {
    var lines = std.mem.tokenizeScalar(u8, @import("geometry").csv, '\n');
    _ = lines.next();
    var cases: usize = 0;
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ',');
        var values: [7]u64 = undefined;
        for (&values) |*v| v.* = try std.fmt.parseInt(u64, fields.next().?, 10);
        const c = try h.Config.init(@intCast(values[0]), @intCast(values[1]));
        try std.testing.expectEqual(values[3], try c.index(values[2]));
        const r = try c.range(@intCast(values[3]));
        try std.testing.expectEqual(values[4], r.start);
        try std.testing.expectEqual(values[5], r.end);
        try std.testing.expectEqual(values[6], c.total_buckets);
        cases += 1;
    }
    try std.testing.expect(cases > 1000);
}
test "empty reports import normalization and mismatch preserve state" {
    const c = try h.Config.init(2, 8);
    var x = try h.Histogram.init(a, c);
    defer x.deinit();
    try std.testing.expect((try x.percentile(0.5)) == null);
    try std.testing.expect((try x.mean()) == null);
    try std.testing.expectError(error.EmptyInput, h.Histogram.sum(a, &.{}));
    var y = try h.Histogram.init(a, try h.Config.init(1, 8));
    defer y.deinit();
    try x.record(2, 7);
    try std.testing.expectError(error.ConfigMismatch, x.drainInto(&y));
    try std.testing.expectEqual(@as(u64, 7), try x.total());
    try std.testing.expectError(error.AliasedStorage, x.drainInto(&x));
    try std.testing.expectError(error.OutOfRange, x.record(256, 1));
    try std.testing.expectError(error.InvalidConfig, x.downsample(a, 3));
    var s = try h.Sparse.init(a, c, &.{ .{ .index = 0, .count = 0 }, .{ .index = 1, .count = 2 } });
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 1), s.entries.len);
    var p = try h.Cumulative.init(a, c, &.{ .{ .index = 1, .count = 2 }, .{ .index = 2, .count = 2 } });
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.entries.len);
    try std.testing.expectError(error.InvalidShape, h.Sparse.init(a, c, &.{.{ .index = c.total_buckets, .count = 0 }}));
    try std.testing.expectError(error.InvalidShape, h.Sparse.init(a, c, &.{ .{ .index = 1, .count = 0 }, .{ .index = 1, .count = 1 } }));
    try std.testing.expectError(error.InvalidShape, h.Cumulative.init(a, c, &.{ .{ .index = 2, .count = 0 }, .{ .index = 1, .count = 0 } }));
}
test "review regressions self snapshot strict downsample and empty overflow batch" {
    var x = try h.Histogram.init(a, try h.Config.init(1, 4));
    defer x.deinit();
    try x.record(0, std.math.maxInt(u64));
    try x.record(1, 1);
    try x.snapshotInto(&x);
    try std.testing.expectError(error.InvalidConfig, x.downsample(a, 1));
    try x.percentilesInto(&.{}, &.{});
    var s = try x.toSparse(a);
    defer s.deinit();
    try s.percentilesInto(&.{}, &.{});
    try std.testing.expectError(error.InvalidShape, h.Cumulative.init(a, x.config, &.{.{ .index = 0, .count = 0 }}));
}
test "sum rejects all mismatched configs before allocation" {
    var x = try h.Histogram.init(a, try h.Config.init(1, 4));
    defer x.deinit();
    var y = try h.Histogram.init(a, try h.Config.init(0, 4));
    defer y.deinit();
    var fail = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.ConfigMismatch, h.Histogram.sum(fail.allocator(), &.{ &x, &y }));
}
test "dense import validates and owns independent counts" {
    const c = try h.Config.init(0, 2);
    var input = [_]u64{ 2, 0, 3 };
    var x = try h.Histogram.fromCounts(a, c, &input);
    defer x.deinit();
    input[0] = 99;
    try std.testing.expectEqual(@as(u64, 5), try x.total());
    try std.testing.expectError(error.InvalidShape, h.Histogram.fromCounts(a, c, &.{ 1, 2 }));
    var invalid = c;
    invalid.total_buckets = 2;
    try std.testing.expectError(error.InvalidConfig, h.Histogram.init(a, invalid));
    try std.testing.expectError(error.InvalidConfig, h.Sparse.init(a, invalid, &.{}));
    try std.testing.expectError(error.InvalidConfig, h.Cumulative.init(a, invalid, &.{}));
}
test "merge and downsample conserve totals across representations" {
    const c = try h.Config.init(3, 8);
    var x = try h.Histogram.init(a, c);
    defer x.deinit();
    for (0..256) |i| try x.record(@intCast(i), @intCast(i % 7 + 1));
    try std.testing.expectEqual(@as(u64, 1018), try x.total());
    var s = try x.toSparse(a);
    defer s.deinit();
    var p = try x.toCumulative(a);
    defer p.deinit();
    var dm = try x.merge(a, &x);
    defer dm.deinit();
    var sm = try s.merge(a, &s);
    defer sm.deinit();
    var pm = try p.merge(a, &p);
    defer pm.deinit();
    try std.testing.expectEqual(@as(u64, 2036), try dm.total());
    try std.testing.expectEqual(@as(u64, 2036), try sm.total());
    try std.testing.expectEqual(@as(u64, 2036), try pm.total());
    var dd = try dm.downsample(a, 1);
    defer dd.deinit();
    var sd = try sm.downsample(a, 1);
    defer sd.deinit();
    var pd = try pm.downsample(a, 1);
    defer pd.deinit();
    var ds = try dd.toSparse(a);
    defer ds.deinit();
    var ps = try pd.toSparse(a);
    defer ps.deinit();
    try std.testing.expectEqual(@as(u64, 2036), try dd.total());
    try std.testing.expectEqualSlices(h.Entry, ds.entries, sd.entries);
    try std.testing.expectEqualSlices(h.Entry, ds.entries, ps.entries);
    var output: [5]?h.Bucket = undefined;
    const requests = [_]f64{ 1, 0.25, 0, 0.5, 0.25 };
    try dd.percentilesInto(&requests, &output);
    for (requests, output) |q, b| {
        try std.testing.expectEqualDeep(b, try sd.percentile(q));
        try std.testing.expectEqualDeep(b, try pd.percentile(q));
    }
    try std.testing.expectApproxEqAbs((try dd.mean()).?, (try pd.mean()).?, 0.0001);
    x.reset();
    try std.testing.expectEqual(@as(u64, 1018), try s.total());
    try std.testing.expectEqual(@as(u64, 1018), try p.total());
}
test "collapsed counter and cumulative overflow fail without changing source" {
    const c = try h.Config.init(2, 4);
    var x = try h.Histogram.init(a, c);
    defer x.deinit();
    try x.record(2, std.math.maxInt(u64));
    try x.record(3, 1);
    var s = try x.toSparse(a);
    defer s.deinit();
    try std.testing.expectError(error.Overflow, x.downsample(a, 0));
    try std.testing.expectError(error.Overflow, s.downsample(a, 0));
    try std.testing.expectError(error.Overflow, s.toCumulative(a));
    try std.testing.expectError(error.Overflow, s.merge(a, &s));
    try std.testing.expectEqual(std.math.maxInt(u64), x.counts[2]);
    var p = try h.Cumulative.init(a, c, &.{.{ .index = 0, .count = std.math.maxInt(u64) }});
    defer p.deinit();
    try std.testing.expectError(error.Overflow, p.merge(a, &p));
    try std.testing.expectEqual(std.math.maxInt(u64), try p.total());
    var output = [_]?h.Bucket{.{ .start = 7, .end = 7, .count = 7 }};
    try std.testing.expectError(error.Overflow, x.percentilesInto(&.{0.5}, &output));
    try std.testing.expectEqual(@as(u64, 7), output[0].?.count);
    try std.testing.expectError(error.InvalidOutput, x.percentilesInto(&.{}, &output));
}
