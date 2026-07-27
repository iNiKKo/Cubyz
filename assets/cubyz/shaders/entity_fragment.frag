#version 460

#include "frame_uniforms.glsl"
#include "shadow.glsl"

layout(location = 0) in vec2 outTexCoord;
layout(location = 1) in vec3 mvVertexPos;
layout(location = 2) in vec3 outSunLight;
layout(location = 4) in vec3 outBlockLight;
layout(location = 3) flat in vec3 normal;

layout(location = 0) out vec4 fragColor;

layout(binding = 0) uniform sampler2D textureSampler;

layout(location = 5) uniform float contrast;

uniform vec3 handLightPositionRelative;
uniform vec3 handLightColor; // zero when nothing light-emitting is currently held
uniform float handLightRadius;

// Real-time point light following the player's held item (e.g. a torch) — see chunk_fragment.frag's
// identical function for the full explanation.
vec3 handLightContribution(vec3 worldPosRelative) {
	float dist = length(worldPosRelative - handLightPositionRelative);
	float normDist = clamp(dist / handLightRadius, 0.0, 1.0);
	float atten = (1.0 - normDist) * (1.0 - normDist);
	float peakHighlight = 1.0 + 0.5 * (1.0 - normDist) * (1.0 - normDist);
	return handLightColor * atten * peakHighlight;
}

float lightVariation(vec3 normal) {
	const vec3 directionalPart = vec3(0, contrast/2, contrast);
	const float baseLighting = 1 - contrast;
	return baseLighting + dot(normal, directionalPart);
}

vec3 square(vec3 x) {
	return x*x;
}

float ditherThresholds[16] = float[16] (
	1/17.0, 9/17.0, 3/17.0, 11/17.0,
	13/17.0, 5/17.0, 15/17.0, 7/17.0,
	4/17.0, 12/17.0, 2/17.0, 10/17.0,
	16/17.0, 8/17.0, 14/17.0, 6/17.0
);

ivec2 random1to2(int v) {
	ivec4 fac = ivec4(11248723, 105436839, 45399083, 5412951);
	int seed = v.x*fac.x ^ fac.y;
	return seed*fac.zw;
}

bool passDitherTest(float alpha) {
	ivec2 screenPos = ivec2(gl_FragCoord.xy);
	screenPos += random1to2(0);
	screenPos &= 3;
	return alpha > ditherThresholds[screenPos.x*4 + screenPos.y];
}

void main() {
	vec3 worldPosRelative = transpose(mat3(viewMatrix))*mvVertexPos;
	float shadowFactor = sampleSunShadow(worldPosRelative, normal, length(mvVertexPos), false)*sampleCloudShadow(worldPosRelative);
	vec3 handLight = handLightContribution(worldPosRelative);
	float handIntensity = max(handLight.r, max(handLight.g, handLight.b));
	float effectiveShadow = mix(shadowFactor, 1.0, clamp(handIntensity * 3.0, 0.0, 1.0));

	vec3 directSunAndShadow = outSunLight * effectiveShadow;
	vec3 selfEmission = (handLightRadius > 0.0) ? handLightColor * 0.7 : vec3(0.0);
	vec3 light = min(max(directSunAndShadow + handLight + outBlockLight, selfEmission), vec3(1.0));
	fragColor = texture(textureSampler, outTexCoord)*vec4(light*lightVariation(normal), 1);
	if(!passDitherTest(fragColor.a)) discard;
	fragColor.a = 1;
}
