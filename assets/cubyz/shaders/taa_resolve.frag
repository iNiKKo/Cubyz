#version 460

// Temporal Anti-Aliasing resolve: blends this frame's (jittered, then resolved-to-average-position)
// color against a history buffer accumulated over previous frames, using reprojection so the blend
// follows camera movement/rotation instead of ghosting on every pan. Runs where FXAA runs — after
// deferredRenderPassPipeline has already composited bloom/god-rays/fog into a plain LDR image.
//
// Reprojection deliberately avoids ever reconstructing an *absolute* world position in the shader
// (this engine uses double-precision player positions specifically because single-precision floats
// lose too much accuracy at large world coordinates — see playerPositionInteger/Fraction elsewhere in
// this codebase). Instead: reconstruct this frame's camera-*relative* world offset from depth (the
// same interpolated-corner-ray technique deferred_render_pass.frag uses for fog), add the
// previous-frame-camera-relative delta (cameraDelta, computed in f64 on the CPU), then transform that
// by *last* frame's un-jittered view-projection matrix to get last frame's clip position.

layout(location = 0) out vec4 fragColor;

layout(location = 0) in vec2 texCoords;

layout(binding = 3) uniform sampler2D currentColor;
layout(binding = 4) uniform sampler2D currentDepth;
layout(binding = 6) uniform sampler2D historyColor;

layout(location = 0) uniform vec2 tanXY;
layout(location = 1) uniform float zNear;
layout(location = 2) uniform float zFar;
layout(location = 3) uniform mat4 invViewMatrix;
// Last frame's *un-jittered* view-projection matrix, camera-relative (no translation component needed
// since everything here is relative to the current camera already via cameraDelta below).
layout(location = 4) uniform mat4 lastViewProjMatrix;
// This frame's camera position minus last frame's camera position, in world space — added to the
// reconstructed camera-relative offset before reprojecting, so a moving camera reprojects correctly.
layout(location = 5) uniform vec3 cameraDelta;
layout(location = 6) uniform float historyBlendFactor;
layout(location = 7) flat in vec3[4] directions;

float zFromDepth(float depthBufferValue) {
	return zNear*zFar/(depthBufferValue*(zNear - zFar) + zFar);
}

void main() {
	vec3 currentColorValue = texture(currentColor, texCoords).rgb;

	float rawDepth = texture(currentDepth, texCoords).r;
	if (rawDepth >= 0.999999) {
		// Sky/background: no meaningful depth to reproject with — just take the current frame's color
		// (matches deferred_render_pass.frag's own "never touch background pixels" rule for fog).
		fragColor = vec4(currentColorValue, 1.0);
		return;
	}

	vec3 direction = texCoords.x*(
		texCoords.y*directions[0] + (1 - texCoords.y)*directions[1]
	) + (1 - texCoords.x)*(
		texCoords.y*directions[2] + (1 - texCoords.y)*directions[3]
	);
	float dist = zFromDepth(rawDepth);
	// Camera-relative world offset of this pixel's surface, this frame:
	vec3 relativeOffset = direction*dist;
	// Same surface's offset relative to *last* frame's camera position:
	vec3 lastFrameRelativeOffset = relativeOffset + cameraDelta;

	vec4 lastClip = lastViewProjMatrix*vec4(lastFrameRelativeOffset, 1.0);
	if (lastClip.w <= 1e-4) {
		// Behind last frame's camera (e.g. just came around a corner) — no valid history sample.
		fragColor = vec4(currentColorValue, 1.0);
		return;
	}
	vec2 lastNdc = lastClip.xy/lastClip.w;
	vec2 lastUv = lastNdc*0.5 + 0.5;

	if (lastUv.x < 0.0 || lastUv.x > 1.0 || lastUv.y < 0.0 || lastUv.y > 1.0) {
		// Reprojects outside the screen (camera turned/moved) — nothing to blend with.
		fragColor = vec4(currentColorValue, 1.0);
		return;
	}

	vec3 historyColorValue = texture(historyColor, lastUv).rgb;

	// Neighborhood clamping: bound the history sample to this frame's local 3x3 color range before
	// blending, so stale history from disoccluded/incorrect-reprojection areas can't linger indefinitely
	// (the standard, cheap alternative to per-object motion vectors — this engine has none of those, so
	// some ghosting on fast-moving entities/the player's own view is expected and accepted here).
	vec3 colorMin = currentColorValue;
	vec3 colorMax = currentColorValue;
	{
		vec3 n;
		n = textureOffset(currentColor, texCoords, ivec2(-1, -1)).rgb; colorMin = min(colorMin, n); colorMax = max(colorMax, n);
		n = textureOffset(currentColor, texCoords, ivec2(0, -1)).rgb; colorMin = min(colorMin, n); colorMax = max(colorMax, n);
		n = textureOffset(currentColor, texCoords, ivec2(1, -1)).rgb; colorMin = min(colorMin, n); colorMax = max(colorMax, n);
		n = textureOffset(currentColor, texCoords, ivec2(-1, 0)).rgb; colorMin = min(colorMin, n); colorMax = max(colorMax, n);
		n = textureOffset(currentColor, texCoords, ivec2(1, 0)).rgb; colorMin = min(colorMin, n); colorMax = max(colorMax, n);
		n = textureOffset(currentColor, texCoords, ivec2(-1, 1)).rgb; colorMin = min(colorMin, n); colorMax = max(colorMax, n);
		n = textureOffset(currentColor, texCoords, ivec2(0, 1)).rgb; colorMin = min(colorMin, n); colorMax = max(colorMax, n);
		n = textureOffset(currentColor, texCoords, ivec2(1, 1)).rgb; colorMin = min(colorMin, n); colorMax = max(colorMax, n);
	}
	historyColorValue = clamp(historyColorValue, colorMin, colorMax);

	fragColor = vec4(mix(currentColorValue, historyColorValue, historyBlendFactor), 1.0);
}
