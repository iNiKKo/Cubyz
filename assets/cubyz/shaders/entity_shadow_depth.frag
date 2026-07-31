#version 460

layout(location = 0) in vec2 outTexCoord;
layout(binding = 0) uniform sampler2D textureSampler;

void main() {

	if (texture(textureSampler, outTexCoord).a < 0.5) discard;
}
