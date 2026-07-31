#version 460

#include "frame_uniforms.glsl"

layout(location = 0) in vec2 inPos;

layout(location = 0) out vec2 localPos;
layout(location = 1) out float cameraDistance;

uniform float planeHeightRelative;

void main() {
	vec3 position = vec3(inPos, planeHeightRelative);
	cameraDistance = length(position);
	gl_Position = projectionMatrix*(viewMatrix*vec4(position, 1));
	localPos = inPos;
}
