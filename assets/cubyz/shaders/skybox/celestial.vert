#version 460

#include "../include/frame_uniforms.glsl"

layout(location = 0) in vec2 pos;

layout(location = 0) out vec2 unitPosition;

layout(location = 1) uniform vec3 worldCenter;
layout(location = 2) uniform vec3 billboardRight;
layout(location = 3) uniform vec3 billboardUp;
layout(location = 4) uniform float billboardSize;

void main() {
	unitPosition = pos;
	vec3 worldPos = worldCenter + billboardRight*pos.x*billboardSize + billboardUp*pos.y*billboardSize;
	gl_Position = projectionMatrix*(viewMatrix*vec4(worldPos, 1));
}
