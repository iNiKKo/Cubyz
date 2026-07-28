#version 460

#include "frame_uniforms.glsl"

layout(location = 0) out vec4 fragColor;

layout(location = 0) in vec2 texCoords;
layout(location = 1) in vec2 normalizedTexCoords;
layout(location = 2) in vec3 direction;

layout(binding = 3) uniform sampler2D color;
layout(binding = 4) uniform sampler2D depthTexture;

layout(location = 1) uniform vec2 tanXY;
layout(location = 2) uniform float zNear;
layout(location = 3) uniform float zFar;

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

	float fogStart = 0.75 / max(1e-5, fogDensity);
	float distFog = max(0.0, effectiveDist - fogStart) * fogDensity * 3.5;

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

vec3 fetch(ivec2 pos) {
	vec4 rgba = texelFetch(color, pos, 0);
	float densityAdjustment = sqrt(dot(tanXY*(normalizedTexCoords*2 - 1), tanXY*(normalizedTexCoords*2 - 1)) + 1);
	float rawDepth = texelFetch(depthTexture, pos, 0).r;
	if (rawDepth < 0.99999) {
		float dist = zFromDepth(rawDepth);
		float playerWorldZ = float(playerPositionInteger.z) + playerPositionFraction.z;
		float fogDistance = calculateFogDistance(dist, densityAdjustment, playerWorldZ, normalize(direction).z, fog.density, fog.fogLower - playerPositionInteger.z, fog.fogHigher - playerPositionInteger.z);
		rgba.rgb = applyFrontfaceFog(fogDistance, fog.color, rgba.rgb);
	}
	return rgba.rgb/rgba.a;
}

vec3 linearSample(ivec2 start) {
	vec3 outColor = vec3(0);
	outColor += fetch(start);
	outColor += fetch(start + ivec2(0, 2));
	outColor += fetch(start + ivec2(2, 0));
	outColor += fetch(start + ivec2(2, 2));
	return outColor*0.25;
}

void main() {
	vec3 bufferData = linearSample(ivec2(texCoords));
	float bloomFactor = max(max(bufferData.x, max(bufferData.y, bufferData.z)) - 1.0, 0);
	fragColor = vec4(bufferData*bloomFactor, 1);
}
