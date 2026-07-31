#version 460

#include "chunk_data.glsl"
#include "frame_uniforms.glsl"

layout(location = 44) uniform mat4 lightSpaceMatrix;

struct FaceData {
	int encodedPositionAndLightIndex;
	int textureAndQuad;
};
layout(std430, binding = 3) buffer _faceData
{
	FaceData faceData[];
};

struct QuadInfo {
	vec3 normal;
	float corners[4][3];
	vec2 cornerUV[4];
	uint textureSlot;
	int opaqueInLod;
	int isFoliage;
};
layout(std430, binding = 4) buffer _quads
{
	QuadInfo quads[];
};

layout(location = 37) uniform vec3 sunDirection;
uniform float waterTime;
uniform bool foliageSway;
uniform vec2 weatherWind;

layout(location = 0) out vec2 uv;
layout(location = 1) flat out int textureIndex;
layout(location = 2) flat out int opaqueInLod;

void main() {
	int faceID = gl_VertexIndex >> 2;
	int vertexID = gl_VertexIndex & 3;
	int chunkID = gl_BaseInstance;
	int voxelSize = chunks[chunkID].voxelSize;
	int encodedPositionAndLightIndex = faceData[faceID].encodedPositionAndLightIndex;
	int textureAndQuad = faceData[faceID].textureAndQuad;
	int quadIndex = textureAndQuad >> 16;

	textureIndex = textureAndQuad & 65535;
	opaqueInLod = quads[quadIndex].opaqueInLod;

	vec3 position = vec3(
		encodedPositionAndLightIndex & 31,
		encodedPositionAndLightIndex >> 5 & 31,
		encodedPositionAndLightIndex >> 10 & 31
	);

	position += vec3(quads[quadIndex].corners[vertexID][0], quads[quadIndex].corners[vertexID][1], quads[quadIndex].corners[vertexID][2]);

	if (quads[quadIndex].isFoliage != 0 && foliageSway) {
		vec3 worldPos = vec3(chunks[chunkID].position.xyz) + position*voxelSize;
		bool isLilyPad = abs(quads[quadIndex].normal.z) > 0.8;
		bool isThinPetalPlane = isLilyPad && quads[quadIndex].opaqueInLod == 0;
		float heightMask = isLilyPad ? 1.0 : clamp(quads[quadIndex].corners[vertexID][2] + 0.2, 0.0, 1.0);
		float scale = (isLilyPad ? 0.060 : 0.030)*0.75;
		if (isThinPetalPlane) scale *= 0.35;

		float windWave = sin(worldPos.x * 1.1 + worldPos.y * 0.7 + waterTime * 2.0) * scale;
		windWave += cos(worldPos.x * 0.5 - worldPos.y * 1.3 + waterTime * 1.4) * (scale * 0.6);

		vec2 windDir = length(weatherWind) > 1e-4 ? normalize(weatherWind) : vec2(0.894, 0.447);
		position.xy += (windDir * windWave * heightMask) / float(voxelSize);
	}

	if (quads[quadIndex].isFoliage != 0 && abs(quads[quadIndex].normal.z) < 0.55) {

		vec3 lightDir = sunDirection;
		float sLen = length(lightDir);
		if (sLen > 1e-4) {
			lightDir /= sLen;
			position += lightDir * 0.25;
		}
	}

	position *= voxelSize;
	position += vec3(chunks[chunkID].position.xyz - playerPositionInteger);
	position -= playerPositionFraction;

	uv = quads[quadIndex].cornerUV[vertexID] * voxelSize;

	gl_Position = lightSpaceMatrix * vec4(position, 1.0);
}
