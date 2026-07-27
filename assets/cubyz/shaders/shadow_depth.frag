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
	if (opaqueInLod == 0) {
		if (!foliageShadowsEnabled) discard;
		// Ground foliage (grass, flowers, crops): use low alpha threshold (0.1) so plant base/stem depth
		// is preserved in the shadow map across all 4 arms of the X-mesh, anchoring the shadow to all corners:
		float animatedIndex = animatedTexture[textureIndex];
		float alpha = texture(textureSampler, vec3(uv, animatedIndex)).a;
		if (alpha < 0.1) discard;
	} else {
		// Tree leaves and transparent block quads (alpha < 0.5 discard for sunbeam cutouts):
		float animatedIndex = animatedTexture[textureIndex];
		float alpha = texture(textureSampler, vec3(uv, animatedIndex)).a;
		if (alpha < 0.5) discard;
	}
}
