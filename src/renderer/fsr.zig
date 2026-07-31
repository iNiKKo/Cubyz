const std = @import("std");

const main = @import("main");
const graphics = main.graphics;
const settings = main.settings;
const c = @import("c");

var easuPipeline: graphics.ComputePipeline = undefined;
var rcasPipeline: graphics.ComputePipeline = undefined;

var easuUniforms: struct {
	con0: c_int,
	con1: c_int,
	con2: c_int,
	con3: c_int,
} = undefined;

var rcasUniforms: struct {
	sharpness: c_int,
} = undefined;

pub var inputFrameBuffer: graphics.FrameBuffer = undefined;

var easuTexture: c_uint = 0;
var rcasTexture: c_uint = 0;

var rcasFBO: c_uint = 0;

var currentInputWidth: u31 = 0;
var currentInputHeight: u31 = 0;
var currentOutputWidth: u31 = 0;
var currentOutputHeight: u31 = 0;

pub fn init() void {
	easuPipeline = graphics.ComputePipeline.init("assets/cubyz/shaders/postprocessing/fsr_easu.comp", "", &easuUniforms);
	rcasPipeline = graphics.ComputePipeline.init("assets/cubyz/shaders/postprocessing/fsr_rcas.comp", "", &rcasUniforms);
	inputFrameBuffer.init(false, c.GL_LINEAR, c.GL_CLAMP_TO_EDGE);
	const initialWidth: u31 = if (main.Window.width > 0) main.Window.width else 1280;
	const initialHeight: u31 = if (main.Window.height > 0) main.Window.height else 720;
	updateSize(initialWidth, initialHeight, initialWidth, initialHeight);
}

pub fn deinit() void {
	easuPipeline.deinit();
	rcasPipeline.deinit();
	inputFrameBuffer.deinit();
	if (easuTexture != 0) {
		c.glDeleteTextures(1, &easuTexture);
		easuTexture = 0;
	}
	if (rcasTexture != 0) {
		c.glDeleteTextures(1, &rcasTexture);
		rcasTexture = 0;
	}
	if (rcasFBO != 0) {
		c.glDeleteFramebuffers(1, &rcasFBO);
		rcasFBO = 0;
	}
}

pub fn updateSize(inputWidth: u31, inputHeight: u31, outputWidth: u31, outputHeight: u31) void {
	if (currentInputWidth != inputWidth or currentInputHeight != inputHeight) {
		currentInputWidth = inputWidth;
		currentInputHeight = inputHeight;
		inputFrameBuffer.updateSize(inputWidth, inputHeight, c.GL_RGBA16F);
	}

	updateOutputSize(outputWidth, outputHeight);
}

pub fn updateOutputSize(outputWidth: u31, outputHeight: u31) void {
	if (currentOutputWidth != outputWidth or currentOutputHeight != outputHeight) {
		currentOutputWidth = outputWidth;
		currentOutputHeight = outputHeight;

		if (easuTexture != 0) c.glDeleteTextures(1, &easuTexture);
		if (rcasTexture != 0) c.glDeleteTextures(1, &rcasTexture);
		if (rcasFBO != 0) c.glDeleteFramebuffers(1, &rcasFBO);

		c.glGenTextures(1, &easuTexture);
		c.glBindTexture(c.GL_TEXTURE_2D, easuTexture);
		c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA16F, outputWidth, outputHeight, 0, c.GL_RGBA, c.GL_FLOAT, null);
		c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
		c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
		c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
		c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);

		c.glGenTextures(1, &rcasTexture);
		c.glBindTexture(c.GL_TEXTURE_2D, rcasTexture);
		c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA16F, outputWidth, outputHeight, 0, c.GL_RGBA, c.GL_FLOAT, null);
		c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
		c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
		c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
		c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);

		c.glGenFramebuffers(1, &rcasFBO);
		c.glBindFramebuffer(c.GL_FRAMEBUFFER, rcasFBO);
		c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, rcasTexture, 0);
		c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
	}
}

pub fn render(inputWidth: u31, inputHeight: u31, outputWidth: u31, outputHeight: u31, targetFBO: c_uint) void {
	updateSize(inputWidth, inputHeight, outputWidth, outputHeight);

	easuPipeline.bind();

	const inW: f32 = @floatFromInt(inputWidth);
	const inH: f32 = @floatFromInt(inputHeight);
	const outW: f32 = @floatFromInt(outputWidth);
	const outH: f32 = @floatFromInt(outputHeight);

	const con0: [4]f32 = .{ inW, inH, 0.0, 0.0 };
	const con1: [4]f32 = .{ inW, inH, 1.0 / inW, 1.0 / inH };
	const con2: [4]f32 = .{ outW, outH, 1.0 / outW, 1.0 / outH };
	const con3: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 };

	c.glUniform4fv(easuUniforms.con0, 1, @ptrCast(&con0));
	c.glUniform4fv(easuUniforms.con1, 1, @ptrCast(&con1));
	c.glUniform4fv(easuUniforms.con2, 1, @ptrCast(&con2));
	c.glUniform4fv(easuUniforms.con3, 1, @ptrCast(&con3));

	inputFrameBuffer.bindTexture(c.GL_TEXTURE0);
	c.glBindImageTexture(1, easuTexture, 0, c.GL_FALSE, 0, c.GL_WRITE_ONLY, c.GL_RGBA16F);

	const groupX: u32 = @intCast(@divFloor(outputWidth + 15, 16));
	const groupY: u32 = @intCast(@divFloor(outputHeight + 15, 16));
	c.glDispatchCompute(groupX, groupY, 1);
	c.glMemoryBarrier(c.GL_SHADER_IMAGE_ACCESS_BARRIER_BIT | c.GL_TEXTURE_FETCH_BARRIER_BIT);

	runRcas(easuTexture, outputWidth, outputHeight, targetFBO);
}

pub fn runRcas(inputTex: c_uint, outputWidth: u31, outputHeight: u31, targetFBO: c_uint) void {
	updateOutputSize(outputWidth, outputHeight);
	rcasPipeline.bind();
	c.glUniform1f(rcasUniforms.sharpness, settings.fsrSharpness);

	c.glActiveTexture(c.GL_TEXTURE0);
	c.glBindTexture(c.GL_TEXTURE_2D, inputTex);
	c.glBindImageTexture(1, rcasTexture, 0, c.GL_FALSE, 0, c.GL_WRITE_ONLY, c.GL_RGBA16F);

	const groupX: u32 = @intCast(@divFloor(outputWidth + 15, 16));
	const groupY: u32 = @intCast(@divFloor(outputHeight + 15, 16));
	c.glDispatchCompute(groupX, groupY, 1);
	c.glMemoryBarrier(c.GL_SHADER_IMAGE_ACCESS_BARRIER_BIT | c.GL_TEXTURE_FETCH_BARRIER_BIT);

	c.glBindFramebuffer(c.GL_READ_FRAMEBUFFER, rcasFBO);
	c.glBindFramebuffer(c.GL_DRAW_FRAMEBUFFER, targetFBO);
	c.glBlitFramebuffer(0, 0, outputWidth, outputHeight, 0, 0, outputWidth, outputHeight, c.GL_COLOR_BUFFER_BIT, c.GL_NEAREST);
	c.glBindFramebuffer(c.GL_FRAMEBUFFER, targetFBO);
	c.glViewport(0, 0, outputWidth, outputHeight);
}
