const std = @import("std");
const Allocator = std.mem.Allocator;
const macos = @import("macos");
const objc = @import("objc");
const math = @import("../../math.zig");

const mtl = @import("api.zig");
const Pipeline = @import("Pipeline.zig");

const log = std.log.scoped(.metal);

const pipeline_descs: []const struct { [:0]const u8, PipelineDescription } =
    &.{
        .{ "bg_color", .{
            .vertex_fn = "full_screen_vertex",
            .fragment_fn = "bg_color_fragment",
            .blending_enabled = false,
        } },
        .{ "cell_bg", .{
            .vertex_fn = "full_screen_vertex",
            .fragment_fn = "cell_bg_fragment",
            .blending_enabled = true,
        } },
        .{ "cell_text", .{
            .vertex_attributes = CellText,
            .vertex_fn = "cell_text_vertex",
            .fragment_fn = "cell_text_fragment",
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "image", .{
            .vertex_attributes = Image,
            .vertex_fn = "image_vertex",
            .fragment_fn = "image_fragment",
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "bg_image", .{
            .vertex_attributes = BgImage,
            .vertex_fn = "bg_image_vertex",
            .fragment_fn = "bg_image_fragment",
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
    };

/// All the comptime-known info about a pipeline, so that
/// we can define them ahead-of-time in an ergonomic way.
const PipelineDescription = struct {
    vertex_attributes: ?type = null,
    vertex_fn: []const u8,
    fragment_fn: []const u8,
    step_fn: mtl.MTLVertexStepFunction = .per_vertex,
    blending_enabled: bool,

    fn initPipeline(
        self: PipelineDescription,
        device: objc.Object,
        library: objc.Object,
        pixel_format: mtl.MTLPixelFormat,
    ) !Pipeline {
        return try .init(self.vertex_attributes, .{
            .device = device,
            .vertex_fn = self.vertex_fn,
            .fragment_fn = self.fragment_fn,
            .vertex_library = library,
            .fragment_library = library,
            .step_fn = self.step_fn,
            .attachments = &.{.{
                .pixel_format = pixel_format,
                .blending_enabled = self.blending_enabled,
            }},
        });
    }
};

/// We create a type for the pipeline collection based on our desc array.
const PipelineCollection = t: {
    var fields: [pipeline_descs.len]std.builtin.Type.StructField = undefined;
    for (pipeline_descs, 0..) |pipeline, i| {
        fields[i] = .{
            .name = pipeline[0],
            .type = Pipeline,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(Pipeline),
        };
    }
    break :t @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
};

/// This contains the state for the shaders used by the Metal renderer.
pub const Shaders = struct {
    library: objc.Object,

    /// Collection of available render pipelines.
    pipelines: PipelineCollection,

    /// Custom shaders to run against the final drawable texture. This
    /// can be used to apply a lot of effects. Each shader is run in sequence
    /// against the output of the previous shader.
    post_pipelines: []const Pipeline,

    /// Non-null only for the process-wide standard pipeline cache. Custom
    /// shader sets remain renderer-owned because their source is user-specific.
    shared: ?*SharedStandardShaders = null,

    /// Set to true when deinited, if you try to deinit a defunct set
    /// of shaders it will just be ignored, to prevent double-free.
    defunct: bool = false,

    /// Initialize our shader set.
    ///
    /// "post_shaders" is an optional list of postprocess shaders to run
    /// against the final drawable texture. This is an array of shader source
    /// code, not file paths.
    pub fn init(
        alloc: Allocator,
        device: objc.Object,
        post_shaders: []const [:0]const u8,
        pixel_format: mtl.MTLPixelFormat,
    ) !Shaders {
        if (post_shaders.len == 0) {
            return try initSharedStandard(alloc, device, pixel_format);
        }

        return try initOwned(alloc, device, post_shaders, pixel_format);
    }

    fn initOwned(
        alloc: Allocator,
        device: objc.Object,
        post_shaders: []const [:0]const u8,
        pixel_format: mtl.MTLPixelFormat,
    ) !Shaders {
        const library = try initLibrary(device);
        errdefer library.msgSend(void, objc.sel("release"), .{});

        var pipelines: PipelineCollection = undefined;

        var initialized_pipelines: usize = 0;

        errdefer inline for (pipeline_descs, 0..) |pipeline, i| {
            if (i < initialized_pipelines) {
                @field(pipelines, pipeline[0]).deinit();
            }
        };

        inline for (pipeline_descs) |pipeline| {
            @field(pipelines, pipeline[0]) = try pipeline[1].initPipeline(
                device,
                library,
                pixel_format,
            );
            initialized_pipelines += 1;
        }

        const post_pipelines: []const Pipeline = initPostPipelines(
            alloc,
            device,
            library,
            post_shaders,
            pixel_format,
        ) catch |err| err: {
            // If an error happens while building postprocess shaders we
            // want to just not use any postprocess shaders since we don't
            // want to block Ghostty from working.
            log.warn("error initializing postprocess shaders err={}", .{err});
            break :err &.{};
        };
        errdefer if (post_pipelines.len > 0) {
            for (post_pipelines) |pipeline| pipeline.deinit();
            alloc.free(post_pipelines);
        };

        return .{
            .library = library,
            .pipelines = pipelines,
            .post_pipelines = post_pipelines,
        };
    }

    pub fn deinit(self: *Shaders, alloc: Allocator) void {
        if (self.defunct) return;
        self.defunct = true;

        if (self.shared) |entry| {
            releaseSharedStandard(entry);
            return;
        }

        self.deinitOwned(alloc);
    }

    fn deinitOwned(self: *Shaders, alloc: Allocator) void {
        // Release our primary shaders
        inline for (pipeline_descs) |pipeline| {
            @field(self.pipelines, pipeline[0]).deinit();
        }
        self.library.msgSend(void, objc.sel("release"), .{});

        // Release our postprocess shaders
        if (self.post_pipelines.len > 0) {
            for (self.post_pipelines) |pipeline| {
                pipeline.deinit();
            }
            alloc.free(self.post_pipelines);
        }
    }
};

const SharedStandardShadersKey = struct {
    device: usize,
    pixel_format: mtl.MTLPixelFormat,

    fn eql(self: SharedStandardShadersKey, other: SharedStandardShadersKey) bool {
        return self.device == other.device and
            self.pixel_format == other.pixel_format;
    }
};

const SharedStandardShaders = struct {
    key: SharedStandardShadersKey,
    resource_allocator: Allocator,
    library: objc.Object,
    pipelines: PipelineCollection,
    post_pipelines: []const Pipeline,
    references: usize,
};

const shared_standard_allocator = std.heap.c_allocator;
var shared_standard_mutex: std.Thread.Mutex = .{};
var shared_standard_entries: std.ArrayListUnmanaged(*SharedStandardShaders) = .empty;
var shared_standard_build_count = std.atomic.Value(usize).init(0);

fn initSharedStandard(
    alloc: Allocator,
    device: objc.Object,
    pixel_format: mtl.MTLPixelFormat,
) !Shaders {
    const key: SharedStandardShadersKey = .{
        .device = @intFromPtr(device.value),
        .pixel_format = pixel_format,
    };

    // Pipeline compilation is expensive and Metal retains significant
    // process-wide compiler state even after duplicate pipelines are
    // released. Serialize cache misses so concurrent surface initialization
    // cannot compile the same standard pipeline collection more than once.
    shared_standard_mutex.lock();
    defer shared_standard_mutex.unlock();

    if (findSharedStandardLocked(key)) |entry| {
        entry.references += 1;
        return shadersFromSharedStandard(entry);
    }

    _ = shared_standard_build_count.fetchAdd(1, .monotonic);
    var candidate = try Shaders.initOwned(alloc, device, &.{}, pixel_format);
    const entry = shared_standard_allocator.create(SharedStandardShaders) catch |err| {
        candidate.deinit(alloc);
        return err;
    };
    entry.* = .{
        .key = key,
        .resource_allocator = alloc,
        .library = candidate.library,
        .pipelines = candidate.pipelines,
        .post_pipelines = candidate.post_pipelines,
        .references = 1,
    };

    shared_standard_entries.append(
        shared_standard_allocator,
        entry,
    ) catch |err| {
        candidate.deinit(alloc);
        shared_standard_allocator.destroy(entry);
        return err;
    };

    candidate.shared = entry;
    return candidate;
}

fn findSharedStandardLocked(
    key: SharedStandardShadersKey,
) ?*SharedStandardShaders {
    for (shared_standard_entries.items) |entry| {
        if (entry.key.eql(key)) return entry;
    }
    return null;
}

fn shadersFromSharedStandard(entry: *SharedStandardShaders) Shaders {
    return .{
        .library = entry.library,
        .pipelines = entry.pipelines,
        .post_pipelines = entry.post_pipelines,
        .shared = entry,
    };
}

fn releaseSharedStandard(entry: *SharedStandardShaders) void {
    var destroy = false;

    shared_standard_mutex.lock();
    std.debug.assert(entry.references > 0);
    entry.references -= 1;
    if (entry.references == 0) {
        for (shared_standard_entries.items, 0..) |candidate, i| {
            if (candidate != entry) continue;
            _ = shared_standard_entries.orderedRemove(i);
            destroy = true;
            break;
        }
        std.debug.assert(destroy);

        if (shared_standard_entries.items.len == 0) {
            shared_standard_entries.deinit(shared_standard_allocator);
            shared_standard_entries = .empty;
        }
    }
    shared_standard_mutex.unlock();

    if (!destroy) return;

    var owned: Shaders = .{
        .library = entry.library,
        .pipelines = entry.pipelines,
        .post_pipelines = entry.post_pipelines,
    };
    owned.deinit(entry.resource_allocator);
    shared_standard_allocator.destroy(entry);
}

/// The uniforms that are passed to our shaders.
pub const Uniforms = extern struct {
    // Note: all of the explicit alignments are copied from the
    // MSL developer reference just so that we can be sure that we got
    // it all exactly right.

    /// The projection matrix for turning world coordinates to normalized.
    /// This is calculated based on the size of the screen.
    projection_matrix: math.Mat align(16),

    /// Size of the screen (render target) in pixels.
    screen_size: [2]f32 align(8),

    /// Size of a single cell in pixels, unscaled.
    cell_size: [2]f32 align(8),

    /// Size of the grid in columns and rows.
    grid_size: [2]u16 align(4),

    /// The padding around the terminal grid in pixels. In order:
    /// top, right, bottom, left.
    grid_padding: [4]f32 align(16),

    /// Bit mask defining which directions to
    /// extend cell colors in to the padding.
    /// Order, LSB first: left, right, up, down
    padding_extend: PaddingExtend align(1),

    /// The minimum contrast ratio for text. The contrast ratio is calculated
    /// according to the WCAG 2.0 spec.
    min_contrast: f32 align(4),

    /// The cursor position and color.
    cursor_pos: [2]u16 align(4),
    cursor_color: [4]u8 align(4),

    /// The background color for the whole surface.
    bg_color: [4]u8 align(4),

    /// Various booleans.
    ///
    /// TODO: Maybe put these in a packed struct, like for OpenGL.
    bools: extern struct {
        /// Whether the cursor is 2 cells wide.
        cursor_wide: bool align(1),

        /// Indicates that colors provided to the shader are already in
        /// the P3 color space, so they don't need to be converted from
        /// sRGB.
        use_display_p3: bool align(1),

        /// Indicates that the color attachments for the shaders have
        /// an `*_srgb` pixel format, which means the shaders need to
        /// output linear RGB colors rather than gamma encoded colors,
        /// since blending will be performed in linear space and then
        /// Metal itself will re-encode the colors for storage.
        use_linear_blending: bool align(1),

        /// Enables a weight correction step that makes text rendered
        /// with linear alpha blending have a similar apparent weight
        /// (thickness) to gamma-incorrect blending.
        use_linear_correction: bool align(1) = false,
    },

    const PaddingExtend = packed struct(u8) {
        left: bool = false,
        right: bool = false,
        up: bool = false,
        down: bool = false,
        _padding: u4 = 0,
    };
};

test "standard shaders reuse pipeline state across surfaces and restores" {
    const testing = std.testing;
    const device_ptr = mtl.MTLCreateSystemDefaultDevice() orelse {
        return error.SkipZigTest;
    };
    const device = objc.Object.fromId(device_ptr);
    defer device.release();

    {
        var active = try Shaders.init(
            testing.allocator,
            device,
            &.{},
            .bgra8unorm,
        );
        defer active.deinit(testing.allocator);

        {
            var hidden = try Shaders.init(
                testing.allocator,
                device,
                &.{},
                .bgra8unorm,
            );
            defer hidden.deinit(testing.allocator);

            try testing.expectEqual(
                active.pipelines.bg_color.state.value,
                hidden.pipelines.bg_color.state.value,
            );
        }

        {
            var restored = try Shaders.init(
                testing.allocator,
                device,
                &.{},
                .bgra8unorm,
            );
            defer restored.deinit(testing.allocator);

            try testing.expectEqual(
                active.pipelines.bg_color.state.value,
                restored.pipelines.bg_color.state.value,
            );
        }
    }

    shared_standard_mutex.lock();
    defer shared_standard_mutex.unlock();
    try testing.expectEqual(@as(usize, 0), shared_standard_entries.items.len);
}

test "concurrent standard shader initialization compiles once" {
    const testing = std.testing;
    const device_ptr = mtl.MTLCreateSystemDefaultDevice() orelse {
        return error.SkipZigTest;
    };
    const device = objc.Object.fromId(device_ptr);
    defer device.release();

    const Context = struct {
        start: *std.Thread.ResetEvent,
        device: objc.Object,
        shaders: ?Shaders = null,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.start.wait();
            self.shaders = Shaders.init(
                std.heap.c_allocator,
                self.device,
                &.{},
                .bgra8unorm_srgb,
            ) catch |err| {
                self.err = err;
                return;
            };
        }
    };

    const thread_count = 5;
    var start: std.Thread.ResetEvent = .{};
    var contexts: [thread_count]Context = undefined;
    var threads: [thread_count]std.Thread = undefined;

    shared_standard_build_count.store(0, .monotonic);
    for (&contexts, &threads) |*context, *thread| {
        context.* = .{
            .start = &start,
            .device = device,
        };
        thread.* = try std.Thread.spawn(.{}, Context.run, .{context});
    }

    start.set();
    for (&threads) |*thread| thread.join();

    defer for (&contexts) |*context| {
        if (context.shaders) |*value| {
            value.deinit(std.heap.c_allocator);
        }
    };

    for (&contexts) |*context| {
        if (context.err) |err| return err;
        try testing.expect(context.shaders != null);
        try testing.expectEqual(
            contexts[0].shaders.?.pipelines.bg_color.state.value,
            context.shaders.?.pipelines.bg_color.state.value,
        );
    }

    try testing.expectEqual(
        @as(usize, 1),
        shared_standard_build_count.load(.monotonic),
    );
}

test "standard shader cache survives a renderer handoff gap" {
    const testing = std.testing;
    const device_ptr = mtl.MTLCreateSystemDefaultDevice() orelse {
        return error.SkipZigTest;
    };
    const device = objc.Object.fromId(device_ptr);
    defer device.release();

    shared_standard_build_count.store(0, .monotonic);

    var hidden = try Shaders.init(
        testing.allocator,
        device,
        &.{},
        .bgra8unorm,
    );
    hidden.deinit(testing.allocator);

    var restored = try Shaders.init(
        testing.allocator,
        device,
        &.{},
        .bgra8unorm,
    );
    restored.deinit(testing.allocator);

    try testing.expectEqual(
        @as(usize, 1),
        shared_standard_build_count.load(.monotonic),
    );
}

/// This is a single parameter for the terminal cell shader.
pub const CellText = extern struct {
    glyph_pos: [2]u32 align(8) = .{ 0, 0 },
    glyph_size: [2]u32 align(8) = .{ 0, 0 },
    bearings: [2]i16 align(4) = .{ 0, 0 },
    grid_pos: [2]u16 align(4),
    color: [4]u8 align(4),
    atlas: Atlas align(1),
    bools: packed struct(u8) {
        no_min_contrast: bool = false,
        is_cursor_glyph: bool = false,
        _padding: u6 = 0,
    } align(1) = .{},

    pub const Atlas = enum(u8) {
        grayscale = 0,
        color = 1,
    };

    test {
        // Minimizing the size of this struct is important,
        // so we test it in order to be aware of any changes.
        try std.testing.expectEqual(32, @sizeOf(CellText));
    }
};

/// This is a single parameter for the cell bg shader.
pub const CellBg = [4]u8;

/// Single parameter for the image shader. See shader for field details.
pub const Image = extern struct {
    grid_pos: [2]f32,
    cell_offset: [2]f32,
    source_rect: [4]f32,
    dest_size: [2]f32,
};

/// Single parameter for the bg image shader.
pub const BgImage = extern struct {
    opacity: f32 align(4),
    info: Info align(1),

    pub const Info = packed struct(u8) {
        position: Position,
        fit: Fit,
        repeat: bool,
        _padding: u1 = 0,

        pub const Position = enum(u4) {
            tl = 0,
            tc = 1,
            tr = 2,
            ml = 3,
            mc = 4,
            mr = 5,
            bl = 6,
            bc = 7,
            br = 8,
        };

        pub const Fit = enum(u2) {
            contain = 0,
            cover = 1,
            stretch = 2,
            none = 3,
        };
    };
};

/// Initialize the MTLLibrary. A MTLLibrary is a collection of shaders.
fn initLibrary(device: objc.Object) !objc.Object {
    const start = try std.time.Instant.now();

    const data = try macos.dispatch.Data.create(
        @embedFile("ghostty_metallib"),
        macos.dispatch.queue.getMain(),
        macos.dispatch.Data.DESTRUCTOR_DEFAULT,
    );
    defer data.release();

    var err: ?*anyopaque = null;
    const library = device.msgSend(
        objc.Object,
        objc.sel("newLibraryWithData:error:"),
        .{
            data,
            &err,
        },
    );
    try checkError(err);

    const end = try std.time.Instant.now();
    log.debug("shader library loaded time={}us", .{end.since(start) / std.time.ns_per_us});

    return library;
}

/// Initialize our custom shader pipelines.
///
/// The shaders argument is a set of shader source code, not file paths.
fn initPostPipelines(
    alloc: Allocator,
    device: objc.Object,
    library: objc.Object,
    shaders: []const [:0]const u8,
    pixel_format: mtl.MTLPixelFormat,
) ![]const Pipeline {
    // If we have no shaders, do nothing.
    if (shaders.len == 0) return &.{};

    // Keeps track of how many shaders we successfully wrote.
    var i: usize = 0;

    // Initialize our result set. If any error happens, we undo everything.
    var pipelines = try alloc.alloc(Pipeline, shaders.len);
    errdefer {
        for (pipelines[0..i]) |pipeline| {
            pipeline.deinit();
        }
        alloc.free(pipelines);
    }

    // Build each shader. Note we don't use "0.." to build our index
    // because we need to keep track of our length to clean up above.
    for (shaders) |source| {
        pipelines[i] = try initPostPipeline(
            device,
            library,
            source,
            pixel_format,
        );
        i += 1;
    }

    return pipelines;
}

/// Initialize a single custom shader pipeline from shader source.
fn initPostPipeline(
    device: objc.Object,
    library: objc.Object,
    data: [:0]const u8,
    pixel_format: mtl.MTLPixelFormat,
) !Pipeline {
    // Create our library which has the shader source
    const post_library = library: {
        const source = try macos.foundation.String.createWithBytes(
            data,
            .utf8,
            false,
        );
        defer source.release();

        var err: ?*anyopaque = null;
        const post_library = device.msgSend(
            objc.Object,
            objc.sel("newLibraryWithSource:options:error:"),
            .{ source, @as(?*anyopaque, null), &err },
        );
        try checkError(err);
        errdefer post_library.msgSend(void, objc.sel("release"), .{});

        break :library post_library;
    };
    defer post_library.msgSend(void, objc.sel("release"), .{});

    return try Pipeline.init(null, .{
        .device = device,
        .vertex_fn = "full_screen_vertex",
        .fragment_fn = "main0",
        .vertex_library = library,
        .fragment_library = post_library,
        .attachments = &.{
            .{
                .pixel_format = pixel_format,
                .blending_enabled = false,
            },
        },
    });
}

fn checkError(err_: ?*anyopaque) !void {
    const nserr = objc.Object.fromId(err_ orelse return);
    const str = @as(
        *macos.foundation.String,
        @ptrCast(nserr.getProperty(?*anyopaque, "localizedDescription").?),
    );

    log.err("metal error={s}", .{str.cstringPtr(.ascii).?});
    return error.MetalFailed;
}
