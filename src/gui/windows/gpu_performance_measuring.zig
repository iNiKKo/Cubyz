const std = @import("std");

const main = @import("main");
const graphics = main.graphics;
const draw = graphics.draw;
const Texture = graphics.Texture;
const Vec2f = main.vec.Vec2f;

const c = @import("c");

const gui = @import("../gui.zig");
const GuiWindow = gui.GuiWindow;
const GuiComponent = gui.GuiComponent;

pub const Samples = enum(u8) {
	screenbuffer_clear,
	clear,
	skybox,
	animation,
	shadow_rendering,
	chunk_rendering_preparation,
	chunk_rendering,
	entity_rendering,
	block_entity_rendering,
	particle_rendering,
	msaa_resolve,
	transparent_rendering_preparation,
	transparent_rendering,
	bloom_extract_downsample,
	bloom_first_pass,
	bloom_second_pass,
	god_rays,
	taa_resolve,
	final_copy,
	gui,
};

const names = [_][]const u8{
	"Screenbuffer clear",
	"Clear",
	"Skybox",
	"Pre-processing Block Animations",
	"Shadow Map Rendering",
	"Chunk Rendering Preparation",
	"Chunk Rendering",
	"Entity Rendering",
	"Block Entity Rendering",
	"Particle Rendering",
	"MSAA Resolve",
	"Transparent Rendering Preparation",
	"Transparent Rendering",
	"Bloom - Extract color and downsample",
	"Bloom - First Pass",
	"Bloom - Second Pass",
	"God Rays",
	"TAA resolve",
	"Copy to screen",
	"GUI Rendering",
};

const buffers = 4;
var curBuffer: u2 = 0;
var queryObjects: [buffers][@typeInfo(Samples).@"enum".fields.len]c_uint = undefined;

var submitted: [buffers][@typeInfo(Samples).@"enum".fields.len]bool = @splat(@splat(false));

var activeSample: ?Samples = null;

pub fn init() void {
	for (&queryObjects) |*buf| {
		c.glGenQueries(buf.len, buf);
		for (buf) |queryObject| {
			c.glBeginQuery(c.GL_TIME_ELAPSED, queryObject);
			c.glEndQuery(c.GL_TIME_ELAPSED);
		}
	}
}

pub fn deinit() void {
	c.glDeleteQueries(queryObjects.len*buffers, @ptrCast(&queryObjects));
}

pub fn startQuery(sample: Samples) void {
	std.debug.assert(activeSample == null);
	activeSample = sample;
	submitted[curBuffer][@intFromEnum(sample)] = true;
	c.glBeginQuery(c.GL_TIME_ELAPSED, queryObjects[curBuffer][@intFromEnum(sample)]);
}

pub fn stopQuery() void {
	std.debug.assert(activeSample != null);
	activeSample = null;
	c.glEndQuery(c.GL_TIME_ELAPSED);
}

pub var window = GuiWindow{
	.relativePosition = .{
		.{.attachedToFrame = .{.selfAttachmentPoint = .upper, .otherAttachmentPoint = .upper}},
		.{.attachedToFrame = .{.selfAttachmentPoint = .lower, .otherAttachmentPoint = .lower}},
	},
	.contentSize = Vec2f{256, 16},
	.isHud = false,
	.showTitleBar = false,
	.hasBackground = false,
	.hideIfMouseIsGrabbed = false,
};

pub fn render() void {
	curBuffer +%= 1;
	var sum: isize = 0;
	var y: f32 = 8;
	inline for (0..queryObjects[curBuffer].len) |i| {
		var result: u32 = 0;
		if (submitted[curBuffer][i]) {
			c.glGetQueryObjectuiv(queryObjects[curBuffer][i], c.GL_QUERY_RESULT, &result);
		}
		draw.print("{s}: {} µs", .{names[i], @divTrunc(result, 1000)}, 0, y, 8);
		sum += result;
		y += 8;
	}

	submitted[curBuffer] = @splat(false);
	draw.print("Total: {} µs", .{@divTrunc(sum, 1000)}, 0, 0, 8);
	const lightManager = main.itemdrop.ItemDisplayManager;
	draw.print("Dropped lights: {} sources -> {} clusters -> {}/{} GPU", .{
		lightManager.droppedLightSourceCount,
		lightManager.droppedLightClusterCount,
		lightManager.activeDropLightCount,
		lightManager.maxDropLights,
	}, 0, y, 8);
	y += 8;
	printWaterDebug(y);
}

const fluid_spread = @import("../../callbacks/block/server/fluid_spread.zig");

fn printWaterDebug(y: f32) void {
	const pos = main.renderer.MeshSelection.selectedBlockPos orelse {
		draw.print("Water debug: no block targeted", .{}, 0, y, 8);
		return;
	};
	const block = main.renderer.mesh_storage.getBlockFromRenderThread(pos[0], pos[1], pos[2]) orelse {
		draw.print("Water debug: chunk not loaded", .{}, 0, y, 8);
		return;
	};
	const waterType = main.blocks.parseBlock("cubyz:water").typ;
	if (block.typ == waterType) {
		const levelLabel: []const u8 = if (block.data == fluid_spread.sourceLevel) "permanent source" else if (block.data == 0) "0 (pending evaporation)" else "flowing";
		draw.print("Water debug: level={} ({s}) at {},{},{}", .{block.data, levelLabel, pos[0], pos[1], pos[2]}, 0, y, 8);
	} else {
		draw.print("Water debug: targeting {s} (not water)", .{block.id()}, 0, y, 8);
	}
}
