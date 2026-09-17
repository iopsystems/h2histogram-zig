# h2histogram for Zig

Native Zig implementation of the h2histogram design. Draft version
`0.1.0-alpha.1`, MIT licensed, targeting Zig 0.16.0. There is no C wrapper
or runtime dependency.

Use a dense `Histogram` during recording, `Sparse` for compact snapshots and
infrequent reporting, and `Cumulative` for repeated percentile queries.
`Config.init(grouping_power, max_value_power)` accepts
`grouping_power < max_value_power <= 64` when the total number of buckets
`2^grouping_power * (max_value_power - grouping_power + 1)` fits `u32`.
Unsupported geometry returns `error.InvalidConfig`.
Integer bucket geometry matches the Rust implementation, including `u64` maximum.
Logarithmic bucket relative error is bounded by `2^-grouping_power`;
values below `2^(grouping_power + 1)` have unit-width buckets.

## Build

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build example
zig fmt --check build.zig build.zig.zon src tests/geometry.zig example
```

Import the `h2histogram` module provided by `build.zig`. See
[example/main.zig](example/main.zig) for an allocator-explicit example.
Tests cover geometry fixtures, arithmetic, lifecycle, native representations,
request validation and failure cleanup at every allocation point.

## API and ownership

All allocating constructors and transforms accept `std.mem.Allocator`. Each
returned owning value must receive exactly one `deinit()`. Do not shallow-copy
owning structs or mutate their implementation fields. Config is a value type;
construct it with `Config.init`. Imported entry slices are copied and may be
released immediately. Entry indices must be strictly ascending and in range,
even for entries whose count is zero. Sparse zero counts and cumulative repeated
prefixes are omitted after validation. Cumulative prefixes must be positive.
`Histogram.fromCounts()` validates the exact dense length and copies the counters.

`Histogram.record(value, count)` changes only the selected `u64` counter with
wrapping addition. It allocates nothing and maintains no cached totals or extrema.
`reset()` reuses storage. `snapshotInto()` copies into an existing equal-config
histogram; `drainInto()` copies then resets. A self-snapshot is a no-op; drain
source and destination must be distinct.
These operations require exclusive access; there are no atomic or concurrent drains.

`add()` preflights every counter for overflow and config mismatch before changing
any counter. `Histogram.sum()` creates a private copy of the first input, applies
checked adds and releases partial results on failure. An empty sum is an error.
Dense, sparse and cumulative `merge()` and `downsample()` return new owned values.
Downsampling accepts a strictly lower grouping power, preserving max power;
equal precision and upsampling are rejected. Collapsed counts and cumulative
prefixes use checked sums.
Native sparse/cumulative transformations do not allocate dense intermediate grids.

`percentile(p)` and `percentilesInto(requests, output)` accept finite fractions
in `[0,1]` and return optional buckets (`null` for empty data). Buckets expose
inclusive `start`/`end` and the original bucket's count. The rank is
`ceil(p * total)`, with exact first/last populated buckets at p0/p1. Interior
ranks use floating-point multiplication and can round for totals above `2^53`;
the C draft uses the same floating-point rank computation.
Output must have room for every request; additional slots are left untouched.
Empty data writes `null` only to the requested slots. The C API instead returns
`H2_EMPTY` without writing output, reflecting its plain-struct status contract.
All requests and output size are validated before any output write. Scalar
queries allocate nothing; batch output is caller-owned and reusable. Dense and
sparse batches scan once per query to avoid scratch allocation; cumulative
queries binary-search prefixes. Batch cost is therefore O(Q*B), O(Q*K), and
O(Q*log K), respectively (plus total validation for dense/sparse).
`total()` and `mean()` are available on all representations; means use bucket
midpoints. `toSparse()` decumulates prefixes and `toCumulative()` builds checked
prefixes.

Dense storage is 8 bytes per configured bucket. Sparse and cumulative storage
hold an index and a u64 count/prefix per populated bucket (including alignment).
Results own their storage independently of sources. Allocation and arithmetic
failures release partial results and leave sources unchanged. Caller output is
unchanged on invalid requests or total overflow.

## Draft limits

Report totals and prefixes are checked `u64`; a total exceeding `u64` returns
`error.Overflow`. Rust can widen report totals, so this is an explicit compatibility
limit. Recording itself still wraps independently per bucket. A bucket that
wraps to zero is empty for reporting; no overflow history is tracked.
No serialization format, thread safety, forced SIMD, benchmark claims or registry release is
provided. This is a native API draft rather than an ABI compatibility promise.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the official Zig style conventions,
project readability rules, and pinned formatting/test commands.
