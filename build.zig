const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const c_translation = b.addTranslateC(.{
        .root_source_file = b.path("miniaudio.h"),
        .target = target,
        .optimize = optimize,
    });

    const dsp_module = b.createModule(.{
        .root_source_file =  b.path("dsp.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Inject miniaudio.c directly into the compilation process
    dsp_module.addImport("miniaudio", c_translation.createModule());
    dsp_module.addCSourceFile(.{
        .file = b.path("miniaudio.c"),
        .flags = &[_][]const u8{ "-std=c99" }, // Force C99 standard
    });

    // Create a shared library
    const lib = b.addLibrary(.{
        .name = "dsp",
        .linkage = .dynamic,
        .root_module = dsp_module 
    });

    // Output the final compiled library into the project folder
    b.installArtifact(lib);
}
