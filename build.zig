const std = @import("std");

pub fn build(b: *std.Build) void {
    const yosys_data_dir =
        b.option([]const u8, "yosys_data_dir", "yosys data dir (per yosys-config --datdir)") orelse
        guessYosysDataDir(b);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zxxrtl", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addIncludePath(.{
        .cwd_relative = b.fmt("{s}/include/backends/cxxrtl/runtime", .{yosys_data_dir}),
    });

    const lib = b.addStaticLibrary(.{
        .name = "zxxrtl",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(lib);

    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}

pub fn guessYosysDataDir(b: *std.Build) []const u8 {
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "yosys-config", "--datdir" },
        .expand_arg0 = .expand,
    }) catch @panic("couldn't run yosys-config; please supply -Dyosys_data_dir");
    return std.mem.trim(u8, result.stdout, "\n");
}
