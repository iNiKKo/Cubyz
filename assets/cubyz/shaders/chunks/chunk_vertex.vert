#version 460

#include "chunk_data.glsl"
#include "frame_uniforms.glsl"

layout(location = 0) out vec3 mvVertexPos;
layout(location = 1) out vec3 direction;
layout(location = 2) out vec3 outSunLight;
layout(location = 3) out vec2 uv;
layout(location = 4) flat out vec3 normal;
layout(location = 5) flat out int textureIndex;
layout(location = 6) flat out int isBackFace;
layout(location = 7) flat out float distanceForLodCheck;
layout(location = 8) flat out int opaqueInLod;
layout(location = 9) out vec3 outBlockLight;
layout(location = 10) flat out int isFoliage;
layout(location = 11) out vec3 worldPos;

layout(location = 0) uniform vec3 ambientLight;

#ifdef ENTITY
layout(location = 14) uniform mat4 modelMatrix;
#endif

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

layout(std430, binding = 10) buffer _lightData
{
	uint lightData[];
};

vec3 square(vec3 x) {
	return x*x;
}

void main() {
	int faceID = gl_VertexIndex >> 2;
	int vertexID = gl_VertexIndex & 3;
	int chunkID = gl_BaseInstance;
	int voxelSize = chunks[chunkID].voxelSize;
	int encodedPositionAndLightIndex = faceData[faceID].encodedPositionAndLightIndex;
	int textureAndQuad = faceData[faceID].textureAndQuad;
	uint lightIndex = chunks[chunkID].lightStart + 4*(encodedPositionAndLightIndex >> 16);
	uint fullLight = lightData[lightIndex + vertexID];
	vec3 sunLight = vec3(
		fullLight >> 25 & 31u,
		fullLight >> 20 & 31u,
		fullLight >> 15 & 31u
	);
	vec3 blockLight = vec3(
		fullLight >> 10 & 31u,
		fullLight >> 5 & 31u,
		fullLight >> 0 & 31u
	);
	// Kept separate (rather than combined into one clamped magnitude like the old `light` did) so
	// chunk_fragment.frag can apply the real-time sun-shadow factor to only the sun component — a torch's
	// baked blockLight is a completely independent local light source and must never be dimmed by the
	// sun/moon being blocked. Mirrors entity_vertex.vert's outSunLight/outBlockLight split.
	outSunLight = sunLight*ambientLight/31;
	outBlockLight = blockLight/31;
	isBackFace = encodedPositionAndLightIndex>>15 & 1;

	textureIndex = textureAndQuad & 65535;
	int quadIndex = textureAndQuad >> 16;
	vec3 position = vec3(
		encodedPositionAndLightIndex & 31,
		encodedPositionAndLightIndex >> 5 & 31,
		encodedPositionAndLightIndex >> 10 & 31
	);

	normal = quads[quadIndex].normal;

	position += vec3(quads[quadIndex].corners[vertexID][0], quads[quadIndex].corners[vertexID][1], quads[quadIndex].corners[vertexID][2]);
#ifdef ENTITY
	// Offset by one to account for block position in chunk
	position = (modelMatrix*vec4(position - vec3(1), 1)).xyz + vec3(1);
#endif
	position *= voxelSize;
	worldPos = vec3(chunks[chunkID].position.xyz) + position;
	position = worldPos - (vec3(playerPositionInteger) + playerPositionFraction);

	direction = position;

	vec4 mvPos = viewMatrix*vec4(position, 1);
	gl_Position = projectionMatrix*mvPos;
	mvVertexPos = mvPos.xyz;
	distanceForLodCheck = length(mvPos.xyz) + voxelSize;
	uv = quads[quadIndex].cornerUV[vertexID]*voxelSize;
	opaqueInLod = quads[quadIndex].opaqueInLod;
	isFoliage = quads[quadIndex].isFoliage;
}
