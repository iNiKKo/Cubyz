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
uniform float waterTime;
uniform bool foliageSway;

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

	// Match chunk_vertex.vert's "Foliage Sway" wind animation exactly (same formula, same waterTime/
	// foliageSway uniforms) — this shadow depth pass previously had NO sway at all, so the shadow map was
	// always baked from foliage's rest position while the visible leaves swayed continuously every frame.
	// Combined with the shadow map only re-rendering every ~20 frames (~0.33s) while the player is mostly
	// still, this meant the shadow would re-bake from rest position, drift out of sync with the still-
	// swaying visible leaves, then snap back into alignment on the next re-render — a repeating ~0.3s
	// mismatch cycle. Player-reported: "too much motion happening, like difference in shading every 0.2s."
	// Applying the identical sway here means the shadow-casting geometry and the visible geometry are
	// always at the same sway phase whenever the shadow map IS re-rendered, eliminating the mismatch at
	// its source rather than trying to hide it with a faster refresh rate (which would only shrink the
	// mismatch window, not remove it, and cost more shadow-map re-renders per second).
	if (quads[quadIndex].isFoliage != 0 && foliageSway) {
		vec3 worldPos = vec3(chunks[chunkID].position.xyz) + position*voxelSize;
		bool isLilyPad = abs(quads[quadIndex].normal.z) > 0.8;
		float heightMask = isLilyPad ? 1.0 : clamp(quads[quadIndex].corners[vertexID][2] + 0.2, 0.0, 1.0);
		float scale = isLilyPad ? 0.060 : 0.030;

		float windWave = sin(worldPos.x * 1.1 + worldPos.y * 0.7 + waterTime * 2.0) * scale;
		windWave += cos(worldPos.x * 0.5 - worldPos.y * 1.3 + waterTime * 1.4) * (scale * 0.6);
		// Sway is applied in true world units (matching chunk_vertex.vert's worldPos.xy +=), but
		// `position` here is still voxel-local (pre `*= voxelSize`) — divide by voxelSize to convert the
		// world-space displacement back into this shader's local units before adding it in below, so LOD
		// chunks (voxelSize > 1) sway by the same real-world distance as full-resolution ones.
		position.xy += (vec2(windWave, windWave * 0.5) * heightMask) / float(voxelSize);
	}

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
