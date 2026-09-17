const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("h2histogram", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    module.addImport("geometry", b.createModule(.{ .root_source_file = b.path("tests/geometry.zig") }));
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Run behavioral and allocation-failure tests").dependOn(&b.addRunArtifact(tests).step);
    const example = b.addExecutable(.{ .name = "h2histogram-example", .root_module = b.createModule(.{ .root_source_file = b.path("example/main.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "h2histogram", .module = module }} }) });
    b.installArtifact(example);
    b.step("example", "Run the example").dependOn(&b.addRunArtifact(example).step);
}
