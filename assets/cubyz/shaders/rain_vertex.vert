#version 460

#include "include/frame_uniforms.glsl"

layout(location = 0) in vec3 pos;
layout(location = 1) in vec3 color;

layout(location = 0) out vec3 vColor;

void main() {
	vColor = color;
	gl_Position = projectionMatrix*(viewMatrix*vec4(pos, 1));
}
