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
	float horizontalDistance = length(worldPos.xy - playerWorldXY);
	if (weatherMask) {
		float weatherHaze = weatherFogStrength*smoothstep(8.0, 76.0, horizontalDistance);
		if (weatherHaze <= 0.001) discard;
		vec3 pattern = texture(textureSampler, vec3(worldPos.xy*0.18, animatedTexture[textureIndex])).rgb;

		vec3 deepWeatherWater = weatherFogColor;
		float weatherBlend = 1.0 - exp(-8.0*weatherHaze);
		vec3 colour = mix(pattern*0.20 + vec3(0.008, 0.045, 0.070), deepWeatherWater, weatherBlend);

		float alpha = 1.0 - exp(-25.0*weatherHaze);
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
