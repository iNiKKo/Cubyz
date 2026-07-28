#version 460

#include "frame_uniforms.glsl"

layout(location = 0) out vec4 fragColor;

layout(location = 0) in vec2 texCoords;
layout(location = 1) flat in vec3[4] directions;

layout(binding = 3) uniform sampler2D color;

layout(binding = 4) uniform sampler2D depthTexture;

layout(binding = 5) uniform sampler2D bloomColor;

layout(binding = 10) uniform sampler2D godRayColor;

layout(location = 1) uniform vec2 tanXY;
layout(location = 2) uniform float zNear;
layout(location = 3) uniform float zFar;
uniform vec3 godRayTint;

struct Fog {
	vec3 color;
	float density;
	float fogLower;
	float fogHigher;
};

layout(location = 6) uniform Fog fog;

float zFromDepth(float depthBufferValue) {
	return zNear*zFar/(depthBufferValue*(zNear - zFar) + zFar);
}

float densityIntegral(float dist, float zStart, float zDist, float fogLower, float fogHigher) {
	// The density is constant until fogLower, then gets smaller linearly until reaching fogHigher, past which there is no fog.
	if(zDist < 0) {
		zStart += zDist;
		zDist = -zDist;
	}
	if(abs(zDist) < 0.001) {
		zDist = 0.001;
	}
	float beginLower = min(fogLower, zStart);
	float endLower = min(fogLower, zStart + zDist);
	float beginMid = max(fogLower, min(fogHigher, zStart));
	float endMid = max(fogLower, min(fogHigher, zStart + zDist));
	float midIntegral = -0.5*(endMid - fogHigher)*(endMid - fogHigher)/(fogHigher - fogLower) - -0.5*(beginMid - fogHigher)*(beginMid - fogHigher)/(fogHigher - fogLower);
	if(fogHigher == fogLower) midIntegral = 0;

	return (endLower - beginLower + midIntegral)/zDist*dist;
}

float calculateFogDistance(float dist, float densityAdjustment, float playerWorldZ, float zScale, float fogDensity, float fogLower, float fogHigher) {
	float effectiveDist = dist * densityAdjustment;

	// Distance fog starts at 60% of total max LOD distance (all closer chunks are 100% crystal clear) and
	// ramps up to hide the outer edge of all loaded LOD chunks. Player-reported "the fog at the ends of
	// the LOD (furthest chunks) isn't there or is very weak" was correct: with the previous 0.75 start
	// fraction and 3.5 multiplier, terrain right at the actual edge of the loaded world was still ~42%
	// visible (totalFog = (1-0.75)*3.5 = 0.875, fogFactor = exp(-0.875) ≈ 0.417) — a mild haze, not enough
	// to hide chunks actually disappearing/popping in at the render-distance boundary. Tuned so the ramp
	// starts earlier (0.6, giving more distance to fade smoothly rather than a sudden wall) and reaches
	// ~4% visibility exactly at the edge (totalFog = (1-0.6)*8.0 = 3.2, fogFactor = exp(-3.2) ≈ 0.041).
	float fogStartFraction = 0.6;
	float fogEdgeMultiplier = 8.0;
	float fogStart = fogStartFraction / max(1e-5, fogDensity);
	float distFog = max(0.0, effectiveDist - fogStart) * fogDensity * fogEdgeMultiplier;

	// Height fog (mist layer near ground):
	float heightFog = densityIntegral(effectiveDist, playerWorldZ - playerPositionInteger.z, zScale * effectiveDist, fogLower - playerPositionInteger.z, fogHigher - playerPositionInteger.z) * fogDensity;

	float totalFog = max(distFog, heightFog);
	return -totalFog;
}

vec3 applyFrontfaceFog(float fogDistance, vec3 fogColor, vec3 inColor) {
	float fogFactor = exp(fogDistance);
	inColor *= fogFactor;
	inColor += fogColor;
	inColor -= fogColor*fogFactor;
	return inColor;
}

void main() {
	fragColor = texture(color, texCoords);
	fragColor += texture(bloomColor, texCoords);
	if (godRayTint != vec3(0.0)) {
		fragColor.rgb += texture(godRayColor, texCoords).r * godRayTint;
	}
	vec2 clampedTexCoords = (floor(texCoords*vec2(textureSize(color, 0))) + 0.5)/vec2(textureSize(color, 0));
	vec3 direction = clampedTexCoords.x*(
		clampedTexCoords.y*directions[0] + (1 - clampedTexCoords.y)*directions[1]
	) + (1 - clampedTexCoords.x)*(
		clampedTexCoords.y*directions[2] + (1 - clampedTexCoords.y)*directions[3]
	);
	float rawDepth = texture(depthTexture, texCoords).r;
	// Only apply terrain/height fog to actual world geometry (rawDepth < 0.99999).
	// Open sky background pixels (depth = 1.0) contain the skybox, stars, sun, and moon
	// which sit in outer space and must never be overwritten by atmospheric fog:
	if (rawDepth < 0.999999) {
		float densityAdjustment = sqrt(dot(tanXY*(clampedTexCoords*2 - 1), tanXY*(clampedTexCoords*2 - 1)) + 1);
		float dist = zFromDepth(rawDepth);
		float playerWorldZ = float(playerPositionInteger.z) + playerPositionFraction.z;
		float fogDistance = calculateFogDistance(dist, densityAdjustment, playerWorldZ, normalize(direction).z, fog.density, fog.fogLower - playerPositionInteger.z, fog.fogHigher - playerPositionInteger.z);
		fragColor.rgb = applyFrontfaceFog(fogDistance, fog.color, fragColor.rgb);
	}
	float maxColor = max(1.0, max(fragColor.r, max(fragColor.g, fragColor.b)));
	fragColor.rgb = fragColor.rgb/maxColor;
}
