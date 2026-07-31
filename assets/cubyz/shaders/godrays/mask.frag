#version 460

layout(location = 0) in vec2 depthTexCoords;
layout(location = 1) in vec3 direction;
layout(location = 2) in vec2 screenUv;

layout(location = 0) out vec4 fragColor;

layout(binding = 4) uniform sampler2D depthTexture;
layout(binding = 9) uniform sampler2D cloudCoverageTex;

uniform vec2 cloudCoverageOrigin;
uniform float cloudCoverageWorldSize;
uniform float cloudHeightRelative;
uniform vec3 sunDirection;

uniform vec2 sunScreenPos;
uniform float aspectRatio;

const float cloudOcclusionStrength = 0.85;

const float sunDiscRadius = 0.025;
const float sunDiscFeather = 0.015;

float cloudAttenuation() {
	if (direction.z <= 0.0) return 1.0;
	float t = cloudHeightRelative/direction.z;
	if (t <= 0.0) return 1.0;
	vec2 samplePos = direction.xy*t;
	vec2 uv = (samplePos - cloudCoverageOrigin)/cloudCoverageWorldSize;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return 1.0;
	float coverage = texture(cloudCoverageTex, uv).r;
	return 1.0 - smoothstep(0.45, 0.65, coverage)*cloudOcclusionStrength;
}

void main() {
	float depth = texelFetch(depthTexture, ivec2(depthTexCoords), 0).r;
	float isSky = depth >= 1.0 - 1e-7 ? 1.0 : 0.0;
	vec2 delta = (screenUv - sunScreenPos)*vec2(aspectRatio, 1.0);
	float sunProximity = 1.0 - smoothstep(sunDiscRadius, sunDiscRadius + sunDiscFeather, length(delta));
	float mask = isSky*sunProximity*cloudAttenuation();
	fragColor = vec4(mask, 0, 0, 1);
}
