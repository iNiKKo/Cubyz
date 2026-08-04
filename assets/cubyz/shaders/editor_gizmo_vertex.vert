#version 460

#include "frame_uniforms.glsl"

layout(location = 0) out vec3 mvVertexPos;
layout(location = 1) out flat int axisIndex;

layout(location = 2) uniform vec3 modelPosition;
layout(location = 3) uniform float axisLength;
layout(location = 4) uniform float lineSize;

vec3 offsetVertices[] = vec3[] (
	vec3(-1, -1, -1),
	vec3(-1, -1, 1),
	vec3(-1, 1, -1),
	vec3(-1, 1, 1),
	vec3(1, -1, -1),
	vec3(1, -1, 1),
	vec3(1, 1, -1),
	vec3(1, 1, 1)
);

vec3 axisDir[] = vec3[] (
	vec3(1, 0, 0),
	vec3(0, 1, 0),
	vec3(0, 0, 1)
);

void main() {
	int vertexIndex = gl_VertexIndex%8;
	axisIndex = gl_VertexIndex/8;
	vec3 dir = axisDir[axisIndex];
	vec3 lineCenter = dir*axisLength/2;

	vec3 offsetVector = vec3(lineSize);
	offsetVector += dir*axisLength/2;

	vec3 vertexPos = lineCenter + offsetVertices[vertexIndex]*offsetVector;
	vec4 mvPos = viewMatrix*vec4(vertexPos + modelPosition, 1);
	gl_Position = projectionMatrix*mvPos;
	mvVertexPos = mvPos.xyz;
}
