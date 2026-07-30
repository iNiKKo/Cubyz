#version 460

layout(location = 0) in vec2 outTexCoord;
layout(binding = 0) uniform sampler2D textureSampler;

void main() {
	// Preserve cutout silhouettes (wings, hair, transparent avatar texture regions) without making a
	// semitransparent model cast an opaque rectangular shadow.
	if (texture(textureSampler, outTexCoord).a < 0.5) discard;
}
