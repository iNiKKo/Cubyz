const std = @import("std");

const main = @import("main");
const chunk = main.chunk;
const Entity = main.entity.Entity;
const game = main.game;
const graphics = main.graphics;
const ZonElement = main.ZonElement;
const renderer = main.renderer;
const settings = main.settings;
const utils = main.utils;
const BinaryReader = utils.BinaryReader;
const vec = main.vec;
const Mat4f = vec.Mat4f;
const Vec3d = vec.Vec3d;
const Vec3f = vec.Vec3f;
const NeverFailingAllocator = main.heap.NeverFailingAllocator;
const EntityModel = main.entityModel.EntityModel;

const c = @import("c");
const Self = @This();

pub var entityComponentID: main.entity.EntityComponentId = undefined;
pub const entityComponentVersion = 0;

// ############################# Client only stuff ################################
pub const client = struct {
	pub const Component = struct {
		entityModel: main.entityModel.EntityModelIndex,

		bufferAllocation: graphics.SubAllocation = .{.len = 0, .start = 0},
		matrices: []Mat4f = undefined,
		nodes: []EntityModel.Node = undefined,

		/// Walk-cycle phase accumulator, integrated frame-to-frame in modelRenderer.zig rather than
		/// derived as (elapsedTime * frequency) - that formulation made the cadence jump discontinuously
		/// every time horizontalSpeed changed, since a changing frequency multiplied by a large absolute
		/// elapsed time produces a large phase jump instead of a smooth cadence change.
		walkPhase: f32 = 0,
		/// Shared per-component frame delta tracking, used both for the walk cycle above and for the
		/// layered look-turn easing below - both need "seconds since this component was last updated,"
		/// not a session-wide clock, so one dt computation in modelRenderer.zig serves both.
		lastWalkUpdateTime: f32 = 0,
		hasWalkUpdateTime: bool = false,

		/// Layered look-turn state (visual only - other players' view of this avatar; see
		/// modelRenderer.zig's updateLayeredLookYaw). `rootYaw` is the committed body-facing yaw the whole
		/// model is rendered at; `headYawOffset` is how much of the remaining look difference the head is
		/// currently absorbing on top of that, clamped to a small budget before the root itself turns to
		/// catch up.
		rootYaw: f32 = 0,
		headYawOffset: f32 = 0,
		hasRootYaw: bool = false,
		/// How long the look direction has been actually still (not just within the head's budget - see
		/// modelRenderer.zig's updateLayeredLookYaw for why that distinction matters) - once held long
		/// enough (holdBeforeResetTime) the body re-centers to face it even if the head budget alone was
		/// never exceeded. lastTargetYaw is the previous frame's look yaw, used to measure how fast it's
		/// currently changing.
		lookHoldTime: f32 = 0,
		lastTargetYaw: f32 = 0,

		pub fn deinit(self: Component) void {
			main.globalAllocator.free(self.matrices);
			main.globalAllocator.free(self.nodes);

			main.entity.systems.modelRenderer.client.nodeBuffer.free(self.bufferAllocation);
		}
	};
	pub var components: main.utils.SparseSet(Component, Entity) = .{};

	pub fn init() void {}
	pub fn deinit() void {
		components.deinit(main.globalAllocator);
	}
	pub fn clear() void {
		components.clear();
	}
	pub fn load(entity: Entity, reader: *utils.BinaryReader, version: u32) main.entity.EntityComponentLoadError!void {
		if (version != 0) return error.InvalidComponentVersion;

		const entityModel = reader.readVarInt(u32) catch return error.UnreadableComponentData;

		var ptr: *Component = undefined;
		if (components.get(entity)) |p| {
			ptr = p;
			ptr.deinit();
		} else {
			ptr = components.add(main.globalAllocator, entity);
		}
		ptr.* = Component{
			.entityModel = .{.index = entityModel},
		};
		const model = ptr.entityModel.get();

		ptr.matrices = main.globalAllocator.alloc(Mat4f, model.nodeCount);
		ptr.nodes = main.globalAllocator.dupe(EntityModel.Node, model.nodes);
	}
	pub fn unload(entity: Entity) void {
		const ptr = components.fetchRemove(entity) catch return;
		ptr.deinit();
	}
	pub fn get(entity: Entity) ?*Component {
		return components.get(entity);
	}
};

// ############################# Server only stuff ################################

pub const server = struct {
	pub const Component = struct {
		entityModel: main.entityModel.EntityModelIndex,
		pub fn save(self: Component, writer: *utils.BinaryWriter, audience: main.entity.AudienceInfo) main.entity.ComponentSaveBehaviour {
			_ = audience;
			writer.writeVarInt(u32, self.entityModel.index);
			return .save;
		}
	};
	var components: main.utils.SparseSet(Component, Entity) = undefined;
	pub fn init() void {
		components = .{};
	}
	pub fn deinit() void {
		components.deinit(main.globalAllocator);
	}
	pub fn loadFromData(entity: Entity, reader: *utils.BinaryReader, version: u32) main.entity.EntityComponentLoadError!void {
		if (version != 0) return error.InvalidComponentVersion;
		const entityModel = reader.readVarInt(u32) catch return error.UnreadableComponentData;

		put(entity, Component{
			.entityModel = .{.index = entityModel},
		});
	}
	pub fn unload(entity: Entity) void {
		components.remove(entity) catch {};
	}
	pub fn put(entity: Entity, renderComponent: Component) void {
		const ptr = components.get(entity) orelse components.add(main.globalAllocator, entity);
		ptr.* = renderComponent;
		main.entity.server.transmitChange(Self, entity);
	}
	pub fn get(entity: Entity) ?*const Component {
		return components.get(entity);
	}
};
