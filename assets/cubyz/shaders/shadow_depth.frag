#version 460

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
	float animatedIndex = animatedTexture[textureIndex];

	if (opaqueInLod == 0) {
		if (!foliageShadowsEnabled) discard;
		float alpha = texture(textureSampler, vec3(uv, animatedIndex)).a;
		if (alpha < 0.35) discard;
	} else {
		float alpha = texture(textureSampler, vec3(uv, animatedIndex)).a;
		if (alpha < 0.5) discard;
	}
}
