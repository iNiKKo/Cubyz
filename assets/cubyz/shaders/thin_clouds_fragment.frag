#version 460

layout(location = 0) in vec2 localPos;

layout(location = 0) out vec4 fragColor;

uniform vec3 tint;
// thin_clouds.zig's playerXY + wind drift — added to localPos below to recover an absolute world-XY
// noise coordinate (see thin_clouds.zig's doc comment for why localPos alone isn't already that).
uniform vec2 noiseOrigin;
uniform float coverageThreshold;
uniform float maxAlpha;

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

void main() {
	vec2 worldPos = localPos + noiseOrigin;
	float base = valueNoise(worldPos/noiseScale);
	float detail = valueNoise(worldPos/detailNoiseScale);
	float coverage = base*(1.0 - detailWeight) + detail*detailWeight;
	float alpha = smoothstep(coverageThreshold - edgeSoftness, coverageThreshold + edgeSoftness, coverage)*maxAlpha;
	if (alpha <= 0.001) discard;
	fragColor = vec4(tint, alpha);
}
