#version 460

layout(location = 0) in vec2 depthTexCoords;
layout(location = 1) in vec3 direction;
layout(location = 2) in vec2 screenUv;

layout(location = 0) out vec4 fragColor;

layout(binding = 4) uniform sampler2D depthTexture;
layout(binding = 9) uniform sampler2D cloudCoverageTex;

uniform vec2 cloudCoverageOrigin; // player-relative XY origin (world units) of the coverage grid
uniform float cloudCoverageWorldSize; // world-space size (both axes) of the coverage grid
uniform float cloudHeightRelative; // middle of the cloud layer's Z, relative to the player (== camera)
uniform vec3 sunDirection;
// Screen-space position (texcoord [0,1], off-screen e.g. (-10,-10) when the sun/moon is behind the
// camera) of the sun/moon this frame — the *exact* same value the blur pass marches toward, computed
// once CPU-side and shared between both passes so the glow's source and the blur's convergence target
// can never drift apart from each other.
uniform vec2 sunScreenPos;
uniform float aspectRatio; // corrects the proximity test below for non-square viewports

// How much a sky pixel directly behind a cloud is dimmed, mirroring shadow.glsl's sampleCloudShadow
// (kept as a separate, smaller-magnitude constant here since god rays reaching around cloud edges is
// visually fine — this doesn't need to fully black out cloud-covered sky, just noticeably dim it).
const float cloudOcclusionStrength = 0.85;

// Radius (in screen-height units) of the bright disc around sunScreenPos that can seed god rays. This
// mimics rendering just the sun's own small disc in a classic god-ray occlusion pre-pass rather than
// the whole sky — too large a radius (an earlier version used a broad world-space angular falloff
// instead of this) lit up a huge swath of sky as "bright," reading as a diffuse halo covering wherever
// the camera happened to be looking, rather than tight shafts anchored to the sun's actual position.
const float sunDiscRadius = 0.05;
const float sunDiscFeather = 0.03;

// Camera-ray/cloud-layer-plane intersection, mirroring shadow.glsl's sampleCloudShadow but for the
// camera's own view ray (is *this pixel* looking at sky behind a cloud?) rather than a ray toward the
// sun from a lit surface (is *this surface* shadowed by a cloud?) — same plane, different ray.
float cloudAttenuation() {
	if (direction.z <= 0.0) return 1.0; // Ray points level/downward: never reaches the cloud layer.
	float t = cloudHeightRelative/direction.z; // Camera is at the player-relative origin (0,0,0).
	if (t <= 0.0) return 1.0; // Cloud layer is behind the camera along this ray.
	vec2 samplePos = direction.xy*t;
	vec2 uv = (samplePos - cloudCoverageOrigin)/cloudCoverageWorldSize;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return 1.0;
	float coverage = texture(cloudCoverageTex, uv).r;
	return 1.0 - smoothstep(0.45, 0.65, coverage)*cloudOcclusionStrength;
}

void main() {
	float depth = texelFetch(depthTexture, ivec2(depthTexCoords), 0).r;
	float isSky = depth >= 1.0 - 1e-6 ? 1.0 : 0.0;
	vec2 delta = (screenUv - sunScreenPos)*vec2(aspectRatio, 1.0);
	float sunProximity = 1.0 - smoothstep(sunDiscRadius, sunDiscRadius + sunDiscFeather, length(delta));
	float mask = isSky*sunProximity*cloudAttenuation();
	fragColor = vec4(mask, 0, 0, 1);
}
