const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    InvalidConfig,
    OutOfRange,
    Overflow,
    ConfigMismatch,
    InvalidShape,
    InvalidPercentile,
    InvalidOutput,
    EmptyInput,
    AliasedStorage,
    OutOfMemory,
};

pub const Range = struct { start: u64, end: u64 };

pub const Bucket = struct {
    start: u64,
    end: u64,
    count: u64,
};

pub const Entry = struct { index: u32, count: u64 };

pub const Config = struct {
    grouping_power: u8,
    max_value_power: u8,
    total_buckets: u32,

    pub fn init(gp: u8, mvp: u8) Error!Config {
        if (gp >= mvp or mvp > 64) return error.InvalidConfig;
        if (gp >= 32) return error.Overflow;

        const n = (@as(u64, 1) << @intCast(gp)) * (@as(u64, mvp) - gp + 1);
        if (n > std.math.maxInt(u32)) return error.Overflow;
        return .{
            .grouping_power = gp,
            .max_value_power = mvp,
            .total_buckets = @intCast(n),
        };
    }

    pub fn validate(self: Config) Error!void {
        const expected = try Config.init(self.grouping_power, self.max_value_power);
        if (self.total_buckets != expected.total_buckets) return error.InvalidConfig;
    }

    pub fn max(self: Config) u64 {
        return if (self.max_value_power == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(self.max_value_power)) - 1;
    }

    pub fn index(self: Config, value: u64) Error!u32 {
        if (value > self.max()) return error.OutOfRange;

        const gp = self.grouping_power;
        const cutoff = @as(u64, 1) << @intCast(gp + 1);
        if (value < cutoff) return @intCast(value);

        const power: u8 = @intCast(63 - @clz(value));
        return @intCast(cutoff + (@as(u64, power) - gp - 1) * (@as(u64, 1) << @intCast(gp)) + ((value - (@as(u64, 1) << @intCast(power))) >> @intCast(power - gp)));
    }

    pub fn range(self: Config, i: u32) Error!Range {
        if (i >= self.total_buckets) return error.OutOfRange;

        const gp = self.grouping_power;
        const g = i >> @intCast(gp);
        const h = i - (g << @intCast(gp));
        const start = if (g == 0) @as(u64, h) else (@as(u64, 1) << @intCast(@as(u32, gp) + g - 1)) + (@as(u64, h) << @intCast(g - 1));
        const width = if (g == 0) @as(u64, 1) else @as(u64, 1) << @intCast(g - 1);
        return .{ .start = start, .end = start + (width - 1) };
    }

    fn eql(x: Config, y: Config) bool {
        return x.grouping_power == y.grouping_power and x.max_value_power == y.max_value_power;
    }
};

fn checked(x: u64, y: u64) Error!u64 {
    return std.math.add(u64, x, y) catch error.Overflow;
}

fn validateP(p: f64) Error!void {
    if (!std.math.isFinite(p) or p < 0 or p > 1) return error.InvalidPercentile;
}

fn validateOutput(ps: []const f64, out: []?Bucket) Error!void {
    if (ps.len != out.len) return error.InvalidOutput;
    for (ps) |p| try validateP(p);
}

fn rank(p: f64, n: u64) u64 {
    if (p == 0) return 1;
    if (p == 1) return n;

    const r = @ceil(p * @as(f64, @floatFromInt(n)));
    if (r >= @as(f64, @floatFromInt(n))) return n;
    return @max(1, @as(u64, @intFromFloat(r)));
}

fn bucket(c: Config, i: u32, n: u64) Bucket {
    const r = c.range(i) catch unreachable;
    return .{
        .start = r.start,
        .end = r.end,
        .count = n,
    };
}

fn midpoint(b: Bucket) f64 {
    return @as(f64, @floatFromInt(b.start)) + @as(f64, @floatFromInt(b.end - b.start)) / 2;
}

pub const Histogram = struct {
    allocator: Allocator,
    config: Config,
    counts: []u64,

    pub fn init(a: Allocator, c: Config) Error!Histogram {
        try c.validate();
        const counts = try a.alloc(u64, c.total_buckets);
        @memset(counts, 0);
        return .{
            .allocator = a,
            .config = c,
            .counts = counts,
        };
    }

    pub fn fromCounts(a: Allocator, c: Config, input: []const u64) Error!Histogram {
        try c.validate();
        if (input.len != c.total_buckets) return error.InvalidShape;
        return .{
            .allocator = a,
            .config = c,
            .counts = try a.dupe(u64, input),
        };
    }

    pub fn deinit(self: *Histogram) void {
        self.allocator.free(self.counts);
        self.* = undefined;
    }

    pub fn record(self: *Histogram, value: u64, count: u64) Error!void {
        self.counts[try self.config.index(value)] +%= count;
    }

    pub fn reset(self: *Histogram) void {
        @memset(self.counts, 0);
    }

    pub fn snapshotInto(self: *const Histogram, out: *Histogram) Error!void {
        if (!self.config.eql(out.config)) return error.ConfigMismatch;
        if (self.counts.ptr == out.counts.ptr) return;
        @memcpy(out.counts, self.counts);
    }

    pub fn drainInto(self: *Histogram, out: *Histogram) Error!void {
        if (self.counts.ptr == out.counts.ptr) return error.AliasedStorage;
        try self.snapshotInto(out);
        self.reset();
    }

    pub fn add(self: *Histogram, other: *const Histogram) Error!void {
        if (!self.config.eql(other.config)) return error.ConfigMismatch;
        for (self.counts, other.counts) |x, y| {
            _ = try checked(x, y);
        }
        for (self.counts, other.counts) |*x, y| x.* += y;
    }

    pub fn sum(a: Allocator, inputs: []const *const Histogram) Error!Histogram {
        if (inputs.len == 0) return error.EmptyInput;
        for (inputs[1..]) |x| {
            if (!inputs[0].config.eql(x.config)) return error.ConfigMismatch;
        }

        var out = try Histogram.init(a, inputs[0].config);
        errdefer out.deinit();

        @memcpy(out.counts, inputs[0].counts);
        for (inputs[1..]) |x| {
            for (out.counts, x.counts) |*dst, src| dst.* = try checked(dst.*, src);
        }

        return out;
    }

    pub fn merge(self: *const Histogram, a: Allocator, other: *const Histogram) Error!Histogram {
        return sum(a, &.{ self, other });
    }

    pub fn downsample(self: *const Histogram, a: Allocator, gp: u8) Error!Histogram {
        if (gp >= self.config.grouping_power) return error.InvalidConfig;

        var out = try Histogram.init(a, try Config.init(gp, self.config.max_value_power));
        errdefer out.deinit();

        for (self.counts, 0..) |n, i| {
            if (n == 0) continue;

            const j = try out.config.index((try self.config.range(@intCast(i))).start);
            out.counts[j] = try checked(out.counts[j], n);
        }

        return out;
    }

    pub fn total(self: *const Histogram) Error!u64 {
        var n: u64 = 0;

        for (self.counts) |v| n = try checked(n, v);

        return n;
    }

    pub fn percentile(self: *const Histogram, p: f64) Error!?Bucket {
        try validateP(p);
        const n = try self.total();
        if (n == 0) return null;
        return self.atRank(rank(p, n));
    }

    fn atRank(self: *const Histogram, r: u64) Bucket {
        var seen: u64 = 0;

        for (self.counts, 0..) |n, i| {
            seen += n;
            if (n != 0 and seen >= r) return bucket(self.config, @intCast(i), n);
        }
        unreachable;
    }

    pub fn percentilesInto(self: *const Histogram, ps: []const f64, out: []?Bucket) Error!void {
        try validateOutput(ps, out);
        if (ps.len == 0) return;

        const n = try self.total();

        for (ps, out) |p, *b| b.* = if (n == 0) null else self.atRank(rank(p, n));
    }

    pub fn mean(self: *const Histogram) Error!?f64 {
        const n = try self.total();
        if (n == 0) return null;

        var sum_: f64 = 0;

        for (self.counts, 0..) |v, i| {
            if (v != 0) sum_ += midpoint(bucket(self.config, @intCast(i), v)) * @as(f64, @floatFromInt(v));
        }

        return sum_ / @as(f64, @floatFromInt(n));
    }

    pub fn toSparse(self: *const Histogram, a: Allocator) Error!Sparse {
        var len: usize = 0;

        for (self.counts) |v| {
            if (v != 0) len += 1;
        }

        const entries = try a.alloc(Entry, len);
        var j: usize = 0;

        for (self.counts, 0..) |v, i| {
            if (v != 0) {
                entries[j] = .{ .index = @intCast(i), .count = v };
                j += 1;
            }
        }

        return .{
            .allocator = a,
            .config = self.config,
            .entries = entries,
        };
    }

    pub fn toCumulative(self: *const Histogram, a: Allocator) Error!Cumulative {
        var s = try self.toSparse(a);
        defer s.deinit();

        return s.toCumulative(a);
    }
};

pub const Sparse = Representation(false);
pub const Cumulative = Representation(true);

fn Representation(comptime cumulative: bool) type {
    return struct {
        const Self = @This();
        allocator: Allocator,
        config: Config,
        entries: []const Entry,

        pub fn init(a: Allocator, c: Config, input: []const Entry) Error!Self {
            try c.validate();
            var previous: ?u32 = null;
            var prefix: u64 = 0;
            var len: usize = 0;

            for (input) |e| {
                if (e.index >= c.total_buckets) return error.InvalidShape;
                if (previous) |p| {
                    if (e.index <= p) return error.InvalidShape;
                }
                previous = e.index;
                if (cumulative) {
                    if (e.count == 0 or e.count < prefix) return error.InvalidShape;
                    if (e.count != prefix) len += 1;
                    prefix = e.count;
                } else if (e.count != 0) {
                    len += 1;
                }
            }

            const entries = try a.alloc(Entry, len);
            var j: usize = 0;
            prefix = 0;
            for (input) |e| {
                const keep = if (cumulative) e.count != prefix else e.count != 0;
                if (keep) {
                    entries[j] = e;
                    j += 1;
                }
                prefix = e.count;
            }

            return .{
                .allocator = a,
                .config = c,
                .entries = entries,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.entries);
            self.* = undefined;
        }

        fn count(self: *const Self, i: usize) u64 {
            return if (cumulative and i > 0) self.entries[i].count - self.entries[i - 1].count else self.entries[i].count;
        }

        pub fn total(self: *const Self) Error!u64 {
            if (cumulative) return if (self.entries.len == 0) 0 else self.entries[self.entries.len - 1].count;

            var n: u64 = 0;

            for (self.entries) |e| n = try checked(n, e.count);

            return n;
        }

        pub fn percentile(self: *const Self, p: f64) Error!?Bucket {
            try validateP(p);
            const n = try self.total();
            if (n == 0) return null;
            return self.atRank(rank(p, n));
        }

        fn atRank(self: *const Self, r: u64) Bucket {
            if (cumulative) {
                var lo: usize = 0;
                var hi = self.entries.len;

                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (self.entries[mid].count < r) lo = mid + 1 else hi = mid;
                }

                return bucket(self.config, self.entries[lo].index, self.count(lo));
            }

            var seen: u64 = 0;

            for (self.entries) |e| {
                seen += e.count;
                if (seen >= r) return bucket(self.config, e.index, e.count);
            }
            unreachable;
        }

        pub fn percentilesInto(self: *const Self, ps: []const f64, out: []?Bucket) Error!void {
            try validateOutput(ps, out);
            if (ps.len == 0) return;

            const n = try self.total();

            for (ps, out) |p, *b| b.* = if (n == 0) null else self.atRank(rank(p, n));
        }

        pub fn mean(self: *const Self) Error!?f64 {
            const n = try self.total();
            if (n == 0) return null;

            var sum_: f64 = 0;

            for (self.entries, 0..) |e, i| {
                const v = self.count(i);
                sum_ += midpoint(bucket(self.config, e.index, v)) * @as(f64, @floatFromInt(v));
            }

            return sum_ / @as(f64, @floatFromInt(n));
        }

        pub fn toSparse(self: *const Self, a: Allocator) Error!Sparse {
            const entries = try a.alloc(Entry, self.entries.len);

            for (self.entries, 0..) |e, i| entries[i] = .{ .index = e.index, .count = self.count(i) };

            return .{
                .allocator = a,
                .config = self.config,
                .entries = entries,
            };
        }

        pub fn toCumulative(self: *const Self, a: Allocator) Error!Cumulative {
            const entries = try a.alloc(Entry, self.entries.len);
            errdefer a.free(entries);

            var n: u64 = 0;

            for (self.entries, 0..) |e, i| {
                n = try checked(n, self.count(i));
                entries[i] = .{ .index = e.index, .count = n };
            }

            return .{
                .allocator = a,
                .config = self.config,
                .entries = entries,
            };
        }

        pub fn merge(self: *const Self, a: Allocator, other: *const Self) Error!Self {
            if (!self.config.eql(other.config)) return error.ConfigMismatch;

            var list: std.ArrayList(Entry) = .empty;
            defer list.deinit(a);

            var i: usize = 0;
            var j: usize = 0;
            var prefix: u64 = 0;

            while (i < self.entries.len or j < other.entries.len) {
                var e: Entry = undefined;
                if (j == other.entries.len or (i < self.entries.len and self.entries[i].index < other.entries[j].index)) {
                    e = .{ .index = self.entries[i].index, .count = self.count(i) };
                    i += 1;
                } else if (i == self.entries.len or other.entries[j].index < self.entries[i].index) {
                    e = .{ .index = other.entries[j].index, .count = other.count(j) };
                    j += 1;
                } else {
                    e = .{
                        .index = self.entries[i].index,
                        .count = try checked(self.count(i), other.count(j)),
                    };
                    i += 1;
                    j += 1;
                }
                if (cumulative) {
                    prefix = try checked(prefix, e.count);
                    e.count = prefix;
                }
                try list.append(a, e);
            }

            return .{
                .allocator = a,
                .config = self.config,
                .entries = try list.toOwnedSlice(a),
            };
        }

        pub fn downsample(self: *const Self, a: Allocator, gp: u8) Error!Self {
            if (gp >= self.config.grouping_power) return error.InvalidConfig;

            const c = try Config.init(gp, self.config.max_value_power);
            var list: std.ArrayList(Entry) = .empty;
            defer list.deinit(a);

            for (self.entries, 0..) |e, i| {
                const j = try c.index((try self.config.range(e.index)).start);
                const n = self.count(i);
                if (list.items.len > 0 and list.items[list.items.len - 1].index == j) {
                    const last = &list.items[list.items.len - 1];
                    last.count = try checked(last.count, n);
                } else try list.append(a, .{ .index = j, .count = n });
            }
            if (cumulative) {
                var prefix: u64 = 0;

                for (list.items) |*e| {
                    prefix = try checked(prefix, e.count);
                    e.count = prefix;
                }
            }

            return .{
                .allocator = a,
                .config = c,
                .entries = try list.toOwnedSlice(a),
            };
        }
    };
}

test {
    _ = @import("tests.zig");
}
