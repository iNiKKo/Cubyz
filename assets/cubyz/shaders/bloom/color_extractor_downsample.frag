#version 460

layout(location = 0) out vec4 fragColor;

layout(location = 0) in vec2 texCoords;

layout(binding = 3) uniform sampler2D color;

vec3 fetch(ivec2 pos) {
	vec4 rgba = texelFetch(color, pos, 0);
	return rgba.rgb;
}

vec3 linearSample(ivec2 start) {
	vec3 outColor = vec3(0);
	outColor += fetch(start);
	outColor += fetch(start + ivec2(0, 2));
	outColor += fetch(start + ivec2(2, 0));
	outColor += fetch(start + ivec2(2, 2));
	return outColor * 0.25;
}

void main() {
	vec3 bufferData = linearSample(ivec2(texCoords));
	float maxColor = max(bufferData.r, max(bufferData.g, bufferData.b));
	float bloomFactor = max(0.0, maxColor - 1.0);
	fragColor = vec4(bufferData * (bloomFactor / max(1e-4, maxColor)), 1.0);
}
