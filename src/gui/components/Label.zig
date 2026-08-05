const std = @import("std");

const main = @import("main");
const graphics = main.graphics;
const draw = graphics.draw;
const TextBuffer = graphics.TextBuffer;
const vec = main.vec;
const Vec2f = vec.Vec2f;

const gui = @import("../gui.zig");
const GuiComponent = gui.GuiComponent;

const Label = @This();

const defaultFontSize: f32 = 16;

pos: Vec2f,
size: Vec2f,
text: TextBuffer,
alpha: f32 = 1,
fontSize: f32 = defaultFontSize,
maxWidth: f32 = undefined,

pub fn init(pos: Vec2f, maxWidth: f32, text: []const u8, alignment: TextBuffer.Alignment) *Label {
	return initWithFontSize(pos, maxWidth, text, alignment, defaultFontSize);
}

pub fn initWithFontSize(pos: Vec2f, maxWidth: f32, text: []const u8, alignment: TextBuffer.Alignment, fontSize: f32) *Label {
	const self = main.globalAllocator.create(Label);
	self.* = Label{
		.text = TextBuffer.init(main.globalAllocator, text, .{}, false, alignment),
		.pos = pos,
		.size = undefined,
		.fontSize = fontSize,
		.maxWidth = maxWidth,
	};
	self.size = self.text.calculateLineBreaks(fontSize, maxWidth);
	return self;
}

pub fn deinit(self: *const Label) void {
	self.text.deinit();
	main.globalAllocator.destroy(self);
}

pub fn toComponent(self: *Label) GuiComponent {
	return .{.label = self};
}

pub fn updateText(self: *Label, newText: []const u8) void {
	const alignment = self.text.alignment;
	self.text.deinit();
	self.text = TextBuffer.init(main.globalAllocator, newText, .{}, false, alignment);
	self.size = self.text.calculateLineBreaks(self.fontSize, self.maxWidth);
}

pub fn render(self: *Label, _: Vec2f) void {
	const oldColor = draw.setColor(@as(u32, @trunc(self.alpha*255)) << 24 | 0xffffff);
	defer draw.restoreColor(oldColor);
	self.text.render(self.pos[0], self.pos[1], self.fontSize);
}
