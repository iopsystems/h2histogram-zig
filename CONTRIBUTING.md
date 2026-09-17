# Contributing

Follow the [official Zig style guide](https://ziglang.org/documentation/0.16.0/#Style-Guide)
and format with **Zig 0.16.0**, the version pinned in CI and `build.zig.zon`.

## Readability

- Use four spaces and same-line opening braces. Aim for about 100 columns;
  split long expressions and initializers into readable parts.
- Separate functions, type declarations, and distinct logical steps with a blank
  line. Keep related setup/cleanup statements together. Avoid both walls of code
  and a blank line after every statement.
- Follow Zig naming: `TitleCase` types and type-producing functions,
  `camelCase` functions, and `snake_case` variables/fields. Avoid redundant names.
- Put lists longer than two items on separate lines with trailing commas when
  following the official guide; do not compress complex declarations to one line.
- Document public API ownership, allocator lifetime, required output size,
  aliasing, errors and invariants with `///` comments. Zig fields are public;
  document invariants rather than suggesting underscore names make them private.
- Pair owned allocations with `defer`/`errdefer`. Preserve source state on checked
  operation failure, and distinguish validation from allocation and mutation.
- Keep recording counter-only. Explain non-obvious bucket arithmetic and avoid
  adding report metadata to the write path without an explicit design decision.

`zig fmt` handles mechanical formatting, but does not choose logical grouping,
meaningful names or useful documentation. Those remain part of code review.

## Verify

```sh
zig fmt build.zig build.zig.zon src tests/geometry.zig example
zig fmt --check build.zig build.zig.zon src tests/geometry.zig example
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build example
```

CI uses these checks. Update the compiler pin, minimum version and this guide
together when deliberately changing toolchain versions. Call the design
**h2histogram**, with no space, in prose.
