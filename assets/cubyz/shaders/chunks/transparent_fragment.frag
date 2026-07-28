#version 460

#include "frame_uniforms.glsl"

layout(location = 0) in vec3 mvVertexPos;
layout(location = 1) in vec3 direction;
layout(location = 2) in vec3 light;
layout(location = 3) in vec2 uv;
layout(location = 4) flat in vec3 normal;
layout(location = 5) flat in int textureIndex;
layout(location = 6) flat in int isBackFace;
layout(location = 7) flat in float distanceForLodCheck;
layout(location = 8) flat in int opaqueInLod;

layout(location = 0, index = 0) out vec4 fragColor;
layout(location = 0, index = 1) out vec4 blendColor;

layout(binding = 0) uniform sampler2DArray textureSampler;
layout(binding = 1) uniform sampler2DArray emissionSampler;
layout(binding = 2) uniform sampler2DArray reflectivityAndAbsorptionSampler;
layout(binding = 3) uniform sampler2D worldColorSampler;
layout(binding = 4) uniform samplerCube reflectionMap;
layout(binding = 5) uniform sampler2D depthTexture;

layout(location = 5) uniform float reflectionMapSize;
layout(location = 6) uniform float contrast;

layout(location = 8) uniform float zNear;
layout(location = 9) uniform float zFar;

uniform bool reflectionsEnabled;

struct Fog {
	vec3 color;
	float density;
	float fogLower;
	float fogHigher;
};

layout(location = 10) uniform Fog fog;

layout(std430, binding = 1) buffer _animatedTexture
{
	float animatedTexture[];
};

struct FogData {
	float fogDensity;
	uint fogColor;
};

layout(std430, binding = 7) buffer _fogData
{
	FogData fogData[];
};

float lightVariation(vec3 normal) {
	const vec3 directionalPart = vec3(0, contrast/2, contrast);
	const float baseLighting = 1 - contrast;
	return baseLighting + dot(normal, directionalPart);
}

vec3 unpackColor(uint color) {
	return vec3(
		color>>16 & 255u,
		color>>8 & 255u,
		color & 255u
	)/255.0;
}

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

float calculateFogDistance(float dist, float densityAdjustment, float zStart, float zScale, float fogDensity, float fogLower, float fogHigher) {
	float distCameraTerrain = densityIntegral(dist*densityAdjustment, zStart, zScale*dist*densityAdjustment, fogLower, fogHigher)*fogDensity;
	float distFromCamera = abs(densityIntegral(mvVertexPos.y*densityAdjustment, zStart, zScale*mvVertexPos.y*densityAdjustment, fogLower, fogHigher))*fogDensity;
	float distFromTerrain = distFromCamera - distCameraTerrain;
	if(distCameraTerrain < 10) { // Resolution range is sufficient.
		return distFromTerrain;
	} else {
		if(distFromTerrain > -5) {
			return distFromTerrain;
		} else if(distFromCamera < 5) {
			return distFromCamera - 10;
		} else {
			return -5;
		}
	}
}

void applyFrontfaceFog(float fogDistance, vec3 fogColor) {
	float fogFactor = exp(fogDistance);
	fragColor.rgb = fogColor*(1 - fogFactor);
	fragColor.a = fogFactor;
}

void applyBackfaceFog(float fogDistance, vec3 fogColor) {
	float fogFactor = exp(-fogDistance);
	fragColor.rgb = fragColor.rgb*fogFactor + fogColor*(1 - fogFactor);
	fragColor.a *= fogFactor;
}

vec4 fixedCubeMapLookup(vec3 v) { // Taken from http://the-witness.net/news/2012/02/seamless-cube-map-filtering/
	float M = max(max(abs(v.x), abs(v.y)), abs(v.z));
	float scale = (reflectionMapSize - 1)/reflectionMapSize;
	if (abs(v.x) != M) v.x *= scale;
	if (abs(v.y) != M) v.y *= scale;
	if (abs(v.z) != M) v.z *= scale;
	return texture(reflectionMap, v);
}

// Screen-Space Reflections (SSR) for water and transparent surfaces
vec3 sampleSSR(vec3 viewPos, vec3 reflDir, vec3 fallbackColor) {
	if (!reflectionsEnabled) return fallbackColor;

	vec3 stepDir = normalize(reflDir) * 0.35;
	float stepSize = 1.0;
	vec3 currentPos = viewPos;

	for (int i = 0; i < 20; i++) {
		currentPos += stepDir * stepSize;
		stepSize *= 1.12;

		vec4 clipPos = projectionMatrix * vec4(currentPos, 1.0);
		if (clipPos.w <= 0.001) continue;
		vec3 ndc = clipPos.xyz / clipPos.w;
		vec2 screenUv = ndc.xy * 0.5 + 0.5;

		if (screenUv.x < 0.01 || screenUv.x > 0.99 || screenUv.y < 0.01 || screenUv.y > 0.99) {
			break;
		}

		float sceneDepth = zFromDepth(texture(depthTexture, screenUv).r);
		float rayDepth = -currentPos.z;

		float depthDiff = rayDepth - sceneDepth;
		if (depthDiff > 0.0 && depthDiff < (1.0 + float(i) * 0.25)) {
			vec3 hitColor = texture(worldColorSampler, screenUv).rgb;
			vec2 edgeFade = smoothstep(vec2(0.0), vec2(0.08), screenUv) * smoothstep(vec2(1.0), vec2(0.92), screenUv);
			float fade = edgeFade.x * edgeFade.y;
			return mix(fallbackColor, hitColor, fade);
		}
	}

	return fallbackColor;
}

void main() {
	float animatedTextureIndex = animatedTexture[textureIndex];
	vec3 textureCoords = vec3(uv, animatedTextureIndex);
	float normalVariation = lightVariation(normal);
	float densityAdjustment = sqrt(dot(mvVertexPos, mvVertexPos))/abs(mvVertexPos.y);
	float dist = zFromDepth(texelFetch(depthTexture, ivec2(gl_FragCoord.xy), 0).r);
	float fogDistance = calculateFogDistance(dist, densityAdjustment, playerPositionFraction.z, normalize(direction).z, fogData[int(animatedTextureIndex)].fogDensity, 1e10, 1e10);
	float airFogDistance = calculateFogDistance(dist, densityAdjustment, playerPositionFraction.z, normalize(direction).z, fog.density, fog.fogLower - playerPositionInteger.z, fog.fogHigher - playerPositionInteger.z);
	vec3 fogColor = unpackColor(fogData[int(animatedTextureIndex)].fogColor);
	vec3 pixelLight = max(light*normalVariation, texture(emissionSampler, textureCoords).r*4);
	vec4 textureColor = texture(textureSampler, textureCoords)*vec4(pixelLight, 1);

	float rawReflectivity = reflectionsEnabled ? texture(reflectivityAndAbsorptionSampler, textureCoords).a : 0.0;
	vec3 reflDir = reflect(normalize(direction), normal);
	vec3 skyRefl = fixedCubeMapLookup(reflDir).rgb;
	vec3 reflColor = sampleSSR(mvVertexPos, reflDir, skyRefl);

	float fresnel = clamp(pow(1.0 + dot(normalize(direction), normal), 2.0), 0.0, 1.0);
	float specularReflectivity = rawReflectivity * (0.5 + 0.5 * fresnel);

	textureColor.rgb *= textureColor.a;
	if (rawReflectivity > 0.01) {
		textureColor.rgb += reflColor * pixelLight * specularReflectivity * 1.20;
	}
	blendColor.rgb = vec3(1.0 - textureColor.a);

	if(isBackFace == 0) {
		vec3 absorption = texture(reflectivityAndAbsorptionSampler, textureCoords).rgb;
		blendColor.rgb *= absorption;

		// Fake reflection:
		// TODO: Change this when it rains.
		// TODO: Normal mapping.
		textureColor.rgb += texture(emissionSampler, textureCoords).rgb;

		if(fogData[int(animatedTextureIndex)].fogDensity == 0.0) {
			// Apply the air fog, compensating for the potentially missing back-face:
			applyFrontfaceFog(airFogDistance, fog.color);
		} else {
			// Apply the block fog:
			applyFrontfaceFog(fogDistance, fogColor);
		}

		// Apply the texture+absorption
		fragColor.rgb *= blendColor.rgb;
		fragColor.rgb += textureColor.rgb;

		// Apply the air fog:
		applyBackfaceFog(airFogDistance, fog.color);
	} else {
		// Apply the air fog:
		applyFrontfaceFog(airFogDistance, fog.color);

		// Apply the texture:
		fragColor.rgb *= blendColor.rgb;
		fragColor.rgb += textureColor.rgb;

		// Apply the block fog:
		if(fogData[int(animatedTextureIndex)].fogDensity == 0.0) {
			// Apply the air fog, compensating for the above line where I compensated for the potentially missing back-face.
			applyBackfaceFog(airFogDistance, fog.color);
		} else {
			applyBackfaceFog(fogDistance, fogColor);
		}
	}
	blendColor.rgb *= fragColor.a;
	fragColor.a = 1;
}
