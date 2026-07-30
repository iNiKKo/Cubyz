const main = @import("main");
const Vec2f = main.vec.Vec2f;

const gui = @import("../gui.zig");
const GuiWindow = gui.GuiWindow;
const ContinuousSlider = @import("../components/ContinuousSlider.zig");
const VerticalList = @import("../components/VerticalList.zig");

pub var window = GuiWindow{
	.contentSize = Vec2f{128, 256},
	.closeIfMouseIsGrabbed = true,
};

const padding: f32 = 16;

fn formatOffset(allocator: main.heap.NeverFailingAllocator, value: f32, comptime axis: []const u8) []const u8 {
	return allocator.print("#ffffffTool {s} Offset: {d:.2}", .{axis, value});
}
fn formatRotation(allocator: main.heap.NeverFailingAllocator, value: f32, comptime axis: []const u8) []const u8 {
	return allocator.print("#ffffffTool Rotation {s}: {d:.0}°", .{axis, value});
}
fn scaleFormatter(allocator: main.heap.NeverFailingAllocator, value: f32) []const u8 {
	return allocator.print("#ffffffTool Scale: {d:.2}x", .{value});
}
fn offsetXFormatter(allocator: main.heap.NeverFailingAllocator, value: f32) []const u8 { return formatOffset(allocator, value, "X (side)"); }
fn offsetYFormatter(allocator: main.heap.NeverFailingAllocator, value: f32) []const u8 { return formatOffset(allocator, value, "Y (forward)"); }
fn offsetZFormatter(allocator: main.heap.NeverFailingAllocator, value: f32) []const u8 { return formatOffset(allocator, value, "Z (up)"); }
fn rotationXFormatter(allocator: main.heap.NeverFailingAllocator, value: f32) []const u8 { return formatRotation(allocator, value, "X"); }
fn rotationYFormatter(allocator: main.heap.NeverFailingAllocator, value: f32) []const u8 { return formatRotation(allocator, value, "Y"); }
fn rotationZFormatter(allocator: main.heap.NeverFailingAllocator, value: f32) []const u8 { return formatRotation(allocator, value, "Z"); }

fn offsetX(value: f32) void { main.itemdrop.ItemDisplayManager.heldToolOffset[0] = value; }
fn offsetY(value: f32) void { main.itemdrop.ItemDisplayManager.heldToolOffset[1] = value; }
fn offsetZ(value: f32) void { main.itemdrop.ItemDisplayManager.heldToolOffset[2] = value; }
fn rotationX(value: f32) void { main.itemdrop.ItemDisplayManager.heldToolRotation[0] = value; }
fn rotationY(value: f32) void { main.itemdrop.ItemDisplayManager.heldToolRotation[1] = value; }
fn rotationZ(value: f32) void { main.itemdrop.ItemDisplayManager.heldToolRotation[2] = value; }
fn scale(value: f32) void { main.itemdrop.ItemDisplayManager.heldToolScale = value; }

pub fn onOpen() void {
	const list = VerticalList.init(.{padding, 16 + padding}, 380, 16);
	list.add(ContinuousSlider.init(.{0, 0}, 240, -1.0, 1.0, main.itemdrop.ItemDisplayManager.heldToolOffset[0], &offsetX, &offsetXFormatter));
	list.add(ContinuousSlider.init(.{0, 0}, 240, -1.0, 1.0, main.itemdrop.ItemDisplayManager.heldToolOffset[1], &offsetY, &offsetYFormatter));
	list.add(ContinuousSlider.init(.{0, 0}, 240, -1.0, 1.0, main.itemdrop.ItemDisplayManager.heldToolOffset[2], &offsetZ, &offsetZFormatter));
	list.add(ContinuousSlider.init(.{0, 0}, 240, -180.0, 180.0, main.itemdrop.ItemDisplayManager.heldToolRotation[0], &rotationX, &rotationXFormatter));
	list.add(ContinuousSlider.init(.{0, 0}, 240, -180.0, 180.0, main.itemdrop.ItemDisplayManager.heldToolRotation[1], &rotationY, &rotationYFormatter));
	list.add(ContinuousSlider.init(.{0, 0}, 240, -180.0, 180.0, main.itemdrop.ItemDisplayManager.heldToolRotation[2], &rotationZ, &rotationZFormatter));
	list.add(ContinuousSlider.init(.{0, 0}, 240, 0.1, 2.0, main.itemdrop.ItemDisplayManager.heldToolScale, &scale, &scaleFormatter));
	list.finish(.center);
	window.rootComponent = list.toComponent();
	window.contentSize = window.rootComponent.?.pos() + window.rootComponent.?.size() + @as(Vec2f, @splat(padding));
	gui.updateWindowPositions();
}

pub fn onClose() void {
	if (window.rootComponent) |*comp| comp.deinit();
}
