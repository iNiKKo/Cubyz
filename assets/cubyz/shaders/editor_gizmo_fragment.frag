#version 460

layout(location = 0) in vec3 mvVertexPos;
layout(location = 1) in flat int axisIndex;

layout(location = 0) out vec4 fragColor;

vec3 axisColor[] = vec3[] (
	vec3(1, 0.15, 0.15),
	vec3(0.15, 1, 0.15),
	vec3(0.25, 0.45, 1)
);

void main() {
	fragColor = vec4(axisColor[axisIndex], 1);
}
