#version 460

#include "frame_uniforms.glsl"

layout(location = 0) out vec3 mvVertexPos;
layout(location = 1) out flat int axisIndex;

layout(location = 2) uniform vec3 modelPosition;
layout(location = 3) uniform float axisLength;
layout(location = 4) uniform float lineSize;
layout(location = 9) uniform int gizmoMode; // 0 = move (3 arrows), 1 = rotate (single Z ring)

const int ringSegments = 32;

vec3 axisDir[] = vec3[] (
	vec3(1, 0, 0),
	vec3(0, 1, 0),
	vec3(0, 0, 1)
);

vec2 quadVertices[] = vec2[] (
	vec2(0, -1),
	vec2(1, -1),
	vec2(1, 1),
	vec2(0, -1),
	vec2(1, 1),
	vec2(0, 1)
);

void main() {
	if (gizmoMode == 1) {
		// A flat ring lying in the XY plane (perpendicular to Z, the only rotation axis
		// currently implemented — see rotation.zig/blueprint.zig, X/Y rotation doesn't exist
		// in the engine yet). Colored/hover-highlighted the same way axisIndex==2 (blue) is.
		axisIndex = 2;
		int segment = gl_VertexIndex/6;
		int vertexIndex = gl_VertexIndex%6;
		float angle0 = (float(segment)/float(ringSegments))*6.28318530718;
		float angle1 = (float(segment + 1)/float(ringSegments))*6.28318530718;
		vec3 dir0 = vec3(cos(angle0), sin(angle0), 0);
		vec3 dir1 = vec3(cos(angle1), sin(angle1), 0);
		vec3 inner0 = dir0*(axisLength - lineSize);
		vec3 outer0 = dir0*(axisLength + lineSize);
		vec3 inner1 = dir1*(axisLength - lineSize);
		vec3 outer1 = dir1*(axisLength + lineSize);
		vec3 ringVertices[6] = vec3[](inner0, outer0, outer1, inner0, outer1, inner1);
		vec3 vertexPos = ringVertices[vertexIndex];
		vec4 mvPos = viewMatrix*vec4(vertexPos + modelPosition, 1);
		gl_Position = projectionMatrix*mvPos;
		mvVertexPos = mvPos.xyz;
		return;
	}

	axisIndex = gl_VertexIndex/6;
	int vertexIndex = gl_VertexIndex%6;
	vec3 dir = axisDir[axisIndex];
	vec3 cameraForward = normalize((transpose(viewMatrix)*vec4(0, 1, 0, 0)).xyz);
	vec3 side = cross(dir, cameraForward);
	if (dot(side, side) < 1e-6) {
		side = cross(dir, vec3(0, 0, 1));
	}
	if (dot(side, side) < 1e-6) {
		side = cross(dir, vec3(0, 1, 0));
	}
	side = normalize(side);

	vec2 q = quadVertices[vertexIndex];
	vec3 vertexPos = dir*(q.x*axisLength) + side*(q.y*lineSize);
	vec4 mvPos = viewMatrix*vec4(vertexPos + modelPosition, 1);
	gl_Position = projectionMatrix*mvPos;
	mvVertexPos = mvPos.xyz;
}
