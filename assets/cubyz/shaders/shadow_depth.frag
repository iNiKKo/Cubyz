#version 460
// Depth-only shadow pass fragment shader.
// The "Grass Shadows" option (foliageShadowsEnabled) controls whether grass/flowers cast shadows.
// Tree leaves perform alpha cutout testing so real-time sunbeams pierce through the canopy.

layout(binding = 0) uniform sampler2DArray textureSampler;

layout(location = 0) in vec2 uv;
layout(location = 1) flat in int textureIndex;
layout(location = 2) flat in int opaqueInLod;

layout(location = 43) uniform bool foliageShadowsEnabled;

layout(std430, binding = 1) buffer _animatedTexture
{
	float animatedTexture[];
};

void main() {
	// Grass blades, flowers, crops, and ground plants (opaqueInLod == 0):
	// Controlled directly by the "Grass Shadows" setting button (foliageShadowsEnabled):
	if (opaqueInLod == 0) {
		if (!foliageShadowsEnabled) discard;
	}

	float animatedIndex = animatedTexture[textureIndex];
	float alpha = texture(textureSampler, vec3(uv, animatedIndex)).a;

	// Tree leaves and non-opaque textures (alpha < 0.99):
	if (alpha < 0.99) {
		if (alpha < 0.5) discard; // Cutout alpha test: transparent leaf openings discard depth
	}
}
