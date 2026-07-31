#version 460

layout(location = 0) out vec4 fragColor;

layout(location = 0) in vec2 texCoords;

layout(binding = 3) uniform sampler2D currentColor;
layout(binding = 4) uniform sampler2D currentDepth;
layout(binding = 6) uniform sampler2D historyColor;

layout(location = 0) uniform vec2 tanXY;
layout(location = 1) uniform float zNear;
layout(location = 2) uniform float zFar;
layout(location = 3) uniform mat4 invViewMatrix;

layout(location = 4) uniform mat4 lastViewProjMatrix;

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

		fragColor = vec4(currentColorValue, 1.0);
		return;
	}

	vec3 direction = texCoords.x*(
		texCoords.y*directions[0] + (1 - texCoords.y)*directions[1]
	) + (1 - texCoords.x)*(
		texCoords.y*directions[2] + (1 - texCoords.y)*directions[3]
	);
	float dist = zFromDepth(rawDepth);

	vec3 relativeOffset = direction*dist;

	vec3 lastFrameRelativeOffset = relativeOffset + cameraDelta;

	vec4 lastClip = lastViewProjMatrix*vec4(lastFrameRelativeOffset, 1.0);
	if (lastClip.w <= 1e-4) {

		fragColor = vec4(currentColorValue, 1.0);
		return;
	}
	vec2 lastNdc = lastClip.xy/lastClip.w;
	vec2 lastUv = lastNdc*0.5 + 0.5;

	if (lastUv.x < 0.0 || lastUv.x > 1.0 || lastUv.y < 0.0 || lastUv.y > 1.0) {

		fragColor = vec4(currentColorValue, 1.0);
		return;
	}

	vec3 historyColorValue = texture(historyColor, lastUv).rgb;

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
