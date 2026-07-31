const std = @import("std");

const main = @import("main");
const graphics = main.graphics;
const settings = main.settings;
const c = @import("c");

var accumPipeline: graphics.ComputePipeline = undefined;

var accumUniforms: struct {
	renderSize: c_int,
	displaySize: c_int,
	jitterOffset: c_int,
	resetHistory: c_int,
} = undefined;

var historyTextures: [2]c_uint = .{ 0, 0 };
var historyIndex: u1 = 0;

var outputTexture: c_uint = 0;
var outputFBO: c_uint = 0;

var currentOutputWidth: u31 = 0;
var currentOutputHeight: u31 = 0;

var isFirstFrame: bool = true;

pub fn init() void {
	accumPipeline = graphics.ComputePipeline.init("assets/cubyz/shaders/postprocessing/fsr2_accumulate.comp", "", &accumUniforms);
	isFirstFrame = true;
}

pub fn deinit() void {
	accumPipeline.deinit();
	for (&historyTextures) |*tex| {
		if (tex.* != 0) {
			c.glDeleteTextures(1, tex);
			tex.* = 0;
		}
	}
	if (outputTexture != 0) {
		c.glDeleteTextures(1, &outputTexture);
		outputTexture = 0;
	}
	if (outputFBO != 0) {
		c.glDeleteFramebuffers(1, &outputFBO);
		outputFBO = 0;
	}
}

pub fn updateSize(outputWidth: u31, outputHeight: u31) void {
	if (currentOutputWidth != outputWidth or currentOutputHeight != outputHeight) {
		currentOutputWidth = outputWidth;
		currentOutputHeight = outputHeight;
		isFirstFrame = true;

		for (&historyTextures) |*tex| {
			if (tex.* != 0) c.glDeleteTextures(1, tex);
			c.glGenTextures(1, tex);
			c.glBindTexture(c.GL_TEXTURE_2D, tex.*);
			c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA16F, outputWidth, outputHeight, 0, c.GL_RGBA, c.GL_FLOAT, null);
			c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
			c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
			c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
			c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
		}

		if (outputTexture != 0) c.glDeleteTextures(1, &outputTexture);
		c.glGenTextures(1, &outputTexture);
		c.glBindTexture(c.GL_TEXTURE_2D, outputTexture);
		c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA16F, outputWidth, outputHeight, 0, c.GL_RGBA, c.GL_FLOAT, null);
		c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
		c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
		c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
		c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);

		if (outputFBO != 0) c.glDeleteFramebuffers(1, &outputFBO);
		c.glGenFramebuffers(1, &outputFBO);
		c.glBindFramebuffer(c.GL_FRAMEBUFFER, outputFBO);
		c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, outputTexture, 0);
		c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
	}
}

pub fn render(inputTexture: c_uint, depthTexture: c_uint, inputWidth: u31, inputHeight: u31, outputWidth: u31, outputHeight: u31, jitter: [2]f32, targetFBO: c_uint) void {
	updateSize(outputWidth, outputHeight);

	const readHistoryIndex = historyIndex;
	const writeHistoryIndex = 1 - historyIndex;
	historyIndex = writeHistoryIndex;

	accumPipeline.bind();

	const inW: f32 = @floatFromInt(inputWidth);
	const inH: f32 = @floatFromInt(inputHeight);
	const outW: f32 = @floatFromInt(outputWidth);
	const outH: f32 = @floatFromInt(outputHeight);

	const renderSizeVec: [4]f32 = .{ inW, inH, 1.0 / inW, 1.0 / inH };
	const displaySizeVec: [4]f32 = .{ outW, outH, 1.0 / outW, 1.0 / outH };

	c.glUniform4fv(accumUniforms.renderSize, 1, @ptrCast(&renderSizeVec));
	c.glUniform4fv(accumUniforms.displaySize, 1, @ptrCast(&displaySizeVec));
	c.glUniform2fv(accumUniforms.jitterOffset, 1, @ptrCast(&jitter));
	c.glUniform1f(accumUniforms.resetHistory, if (isFirstFrame) 1.0 else 0.0);
	isFirstFrame = false;

	c.glActiveTexture(c.GL_TEXTURE0);
	c.glBindTexture(c.GL_TEXTURE_2D, inputTexture);

	c.glActiveTexture(c.GL_TEXTURE1);
	c.glBindTexture(c.GL_TEXTURE_2D, depthTexture);

	c.glActiveTexture(c.GL_TEXTURE2);
	c.glBindTexture(c.GL_TEXTURE_2D, historyTextures[readHistoryIndex]);

	c.glBindImageTexture(3, outputTexture, 0, c.GL_FALSE, 0, c.GL_WRITE_ONLY, c.GL_RGBA16F);
	c.glBindImageTexture(4, historyTextures[writeHistoryIndex], 0, c.GL_FALSE, 0, c.GL_WRITE_ONLY, c.GL_RGBA16F);

	const groupX: u32 = @intCast(@divFloor(outputWidth + 15, 16));
	const groupY: u32 = @intCast(@divFloor(outputHeight + 15, 16));
	c.glDispatchCompute(groupX, groupY, 1);
	c.glMemoryBarrier(c.GL_SHADER_IMAGE_ACCESS_BARRIER_BIT | c.GL_TEXTURE_FETCH_BARRIER_BIT);

	const fsr = @import("fsr.zig");
	fsr.runRcas(outputTexture, outputWidth, outputHeight, targetFBO);
}
