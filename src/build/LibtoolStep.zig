//! A zig builder step that runs "libtool" against a list of libraries
//! in order to create a single combined static library.
const LibtoolStep = @This();

const std = @import("std");
const Step = std.Build.Step;
const RunStep = std.Build.Step.Run;
const LazyPath = std.Build.LazyPath;

pub const Options = struct {
    /// The name of this step.
    name: []const u8,

    /// The filename (not the path) of the file to create. This will
    /// be placed in a unique hashed directory. Use out_path to access.
    out_name: []const u8,

    /// Library files (.a) to combine.
    sources: []LazyPath,
};

/// The step to depend on.
step: *Step,

/// The output file from the libtool run.
output: LazyPath,

/// Run libtool against a list of library files to combine into a single
/// static library.
pub fn create(b: *std.Build, opts: Options) *LibtoolStep {
    const self = b.allocator.create(LibtoolStep) catch @panic("OOM");

    const run_step = RunStep.create(b, b.fmt("libtool {s}", .{opts.name}));
    // macOS /usr/bin/libtool silently skips 8-byte-misaligned .o members
    // (warning only), which drops libghostty_zcu.o and erases all
    // ghostty_surface_* symbols from the combined archive. llvm-libtool-darwin
    // includes misaligned members, preserving the full symbol set. Fall back
    // to plain libtool when llvm-libtool-darwin isn't available.
    const libtool_exe = b.findProgram(
        &.{"llvm-libtool-darwin"},
        &.{"/opt/homebrew/opt/llvm/bin"},
    ) catch "libtool";
    run_step.addArg(libtool_exe);
    run_step.addArgs(&.{ "-static", "-o" });
    const output = run_step.addOutputFileArg(opts.out_name);
    for (opts.sources) |source| run_step.addFileArg(source);

    self.* = .{
        .step = &run_step.step,
        .output = output,
    };

    return self;
}
