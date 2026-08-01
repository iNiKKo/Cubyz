#version 460

#include "frame_uniforms.glsl"

layout(location = 3) in vec2 uv;
layout(location = 4) flat in vec3 normal;
layout(location = 5) flat in int textureIndex;
layout(location = 11) in vec3 worldPos;

layout(location = 0) out vec4 fragColor;

layout(binding = 0) uniform sampler2DArray textureSampler;
layout(std430, binding = 1) buffer _animatedTexture {
	float animatedTexture[];
};
uniform int waterTextureIndex;
uniform float weatherWaterSurfaceMask;
uniform float weatherFogStrength;
uniform vec3 weatherFogColor;

void main() {

	if (textureIndex != waterTextureIndex || normal.z < 0.9) discard;
	float playerWorldZ = float(playerPositionInteger.z) + playerPositionFraction.z;
	bool weatherMask = weatherWaterSurfaceMask > 0.5;

	if ((!weatherMask && worldPos.z <= playerWorldZ + 0.05) || (weatherMask && worldPos.z >= playerWorldZ - 0.05)) discard;

	vec2 playerWorldXY = vec2(float(playerPositionInteger.x), float(playerPositionInteger.y)) + playerPositionFraction.xy;
	if (weatherMask) {
		float weatherFogDensity = max(1e-5, weatherFogStrength/96.0);
		float weatherFogStart = mix(0.60, 0.22, weatherFogStrength)/weatherFogDensity;
		float surfaceDistance = length(vec3(worldPos.xy - playerWorldXY, worldPos.z - playerWorldZ));
		float weatherFogAmount = max(0.0, surfaceDistance - weatherFogStart)*weatherFogDensity*mix(8.0, 14.0, weatherFogStrength);
		weatherFogAmount = mix(weatherFogAmount, weatherFogAmount*weatherFogAmount, weatherFogStrength);
		float weatherHaze = 1.0 - exp(-weatherFogAmount);
		if (weatherHaze <= 0.001) discard;
		vec3 pattern = texture(textureSampler, vec3(worldPos.xy*0.18, animatedTexture[textureIndex])).rgb;

		vec3 deepWeatherWater = vec3(0.012, 0.055, 0.085);
		float airborneFogBlend = smoothstep(0.05, 0.25, playerWorldZ - worldPos.z);
		vec3 weatherWaterTarget = mix(deepWeatherWater, weatherFogColor, airborneFogBlend);
		float weatherBlend = weatherHaze;
		vec3 colour = mix(pattern*0.20 + vec3(0.008, 0.045, 0.070), weatherWaterTarget, weatherBlend);

		float alpha = weatherHaze;
		fragColor = vec4(colour*alpha, alpha);
		return;
	}

	float depthToSurface = worldPos.z - playerWorldZ;
	float proximity = exp(-depthToSurface*0.08);

	float capFade = 1.0 - smoothstep(18.0, 50.0, length(worldPos.xy - playerWorldXY));

	vec3 pattern = texture(textureSampler, vec3(worldPos.xy*0.18, animatedTexture[textureIndex])).rgb;

	vec3 colour = pattern*0.24 + vec3(0.028, 0.115, 0.20)*(0.30 + 0.70*proximity);
	float alpha = mix(0.30, 0.58, proximity)*capFade;
	fragColor = vec4(colour*alpha, alpha);
}
