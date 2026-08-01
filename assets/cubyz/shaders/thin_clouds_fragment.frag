#version 460

layout(location = 0) in vec2 localPos;
layout(location = 1) in float cameraDistance;

layout(location = 0) out vec4 fragColor;

uniform vec3 tint;

uniform vec2 noiseOrigin;
uniform float coverageThreshold;
uniform float maxAlpha;
uniform vec3 fogColor;
uniform float fogDensity;
uniform float weatherFogStrength;
layout(binding = 13) uniform sampler2D sceneDepth;

const float noiseScale = 220.0;
const float detailNoiseScale = noiseScale*0.4;
const float detailWeight = 0.35;
const float edgeSoftness = 0.15;

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

const float horizonFadeStart = 2500.0;
const float horizonFadeEnd = 4000.0;

void main() {
	vec2 sceneTexel = gl_FragCoord.xy/vec2(textureSize(sceneDepth, 0));
	if (gl_FragCoord.z > texture(sceneDepth, sceneTexel).r + 1e-6) discard;
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
