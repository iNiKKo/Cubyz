#version 460

#include "chunk_data.glsl"
#include "frame_uniforms.glsl"

// The cascade's light-space projection*view matrix.
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

	if (quads[quadIndex].isFoliage != 0) {
		// Shift foliage's recorded shadow-map position toward the sun before writing depth. This is what
		// actually closes the gap between a grass blade's base and where its ground shadow starts — every
		// bias tried on the *sampling* side (shadow.glsl) only adjusts how tolerant the read-back is, it
		// can never move where the occluder itself was recorded. This shift was present in an earlier
		// revision (git 71efa93b, "New shadows for grass") gated on the old `opaqueInLod == 0` (which also
		// wrongly caught branches/ore, see the isFoliage/opaqueInLod fix elsewhere), then deleted entirely
		// in a later revision (git 4b9bcd0d) — that deletion is why no amount of shadow.glsl bias tuning
		// after that point ever visibly closed the gap. Restored here gated on the real per-quad isFoliage
		// flag instead.
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
