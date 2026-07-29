#version 460

layout(location = 0) in vec2 localPos;
layout(location = 1) in float cameraDistance;

layout(location = 0) out vec4 fragColor;

uniform vec3 tint;
// thin_clouds.zig's playerXY + wind drift — added to localPos below to recover an absolute world-XY
// noise coordinate (see thin_clouds.zig's doc comment for why localPos alone isn't already that).
uniform vec2 noiseOrigin;
uniform float coverageThreshold;
uniform float maxAlpha;
uniform vec3 fogColor;
uniform float fogDensity;
uniform float weatherFogStrength;

const float noiseScale = 220.0;
const float detailNoiseScale = noiseScale*0.4;
const float detailWeight = 0.35;
const float edgeSoftness = 0.15; // smoothstep width around the threshold — soft wispy edges.

// Standard hash-based 2D value noise (lattice of pseudo-random corner values, bilinearly interpolated
// with a smoothstep-shaped blend) — no CPU-side texture needed, this whole layer is computed on the fly.
float hash(vec2 p) {
	p = fract(p*vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x*p.y);
}

float valueNoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	vec2 u = f*f*(3.0 - 2.0*f);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// This layer is one giant flat quad (planeHalfSize = 4096 blocks in thin_clouds.zig) with no
// distance-based falloff at all — from a first-person camera, a huge span of that flat plane compresses
// into a thin, near-horizontal strip right at the horizon (classic infinite-flat-plane grazing-angle
// behavior), which reads as the cloud layer "stretching as far as it can" toward the horizon rather than
// fading into haze/distance like real clouds or this engine's own 3D cloud layers do. Fading alpha out
// with horizontal distance from the player closes that off — matching the "fade the edge, don't show a
// hard boundary" principle already used for this engine's 3D cloud coverage grid edge and the
// render-distance fog wall.
const float horizonFadeStart = 2500.0; // Blocks — fully opaque before this distance.
const float horizonFadeEnd = 4000.0; // Blocks — fully faded by this distance (inside planeHalfSize=4096, so the plane's own edge is never visible).

void main() {
	vec2 worldPos = localPos + noiseOrigin;
	float base = valueNoise(worldPos/noiseScale);
	float detail = valueNoise(worldPos/detailNoiseScale);
	float coverage = base*(1.0 - detailWeight) + detail*detailWeight;
	float alpha = smoothstep(coverageThreshold - edgeSoftness, coverageThreshold + edgeSoftness, coverage)*maxAlpha;

	float horizontalDist = length(localPos);
	float horizonFade = 1.0 - smoothstep(horizonFadeStart, horizonFadeEnd, horizontalDist);
	alpha *= horizonFade;

	if (alpha <= 0.001) discard;
	vec3 color = tint;
	if (weatherFogStrength > 0.001) {
		float fogStart = mix(0.60, 0.35, weatherFogStrength)/max(1e-5, fogDensity);
		float fogAmount = max(0.0, cameraDistance - fogStart)*fogDensity*mix(8.0, 10.0, weatherFogStrength);
		fogAmount = mix(fogAmount, fogAmount*fogAmount, weatherFogStrength);
		color = mix(color, fogColor, 1.0 - exp(-fogAmount));
	}
	fragColor = vec4(color*alpha, alpha);
}
