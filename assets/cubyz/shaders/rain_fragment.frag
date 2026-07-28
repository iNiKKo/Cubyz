#version 460

layout(location = 0) in vec3 vColor;
layout(location = 0) out vec4 fragColor;

layout(location = 6) uniform float alpha;

void main() {
	fragColor = vec4(vColor, alpha);
}
