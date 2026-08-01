#version 460

#include "include/frame_uniforms.glsl"

layout(location = 0) in vec3 position;

void main() {
	gl_Position = projectionMatrix*(viewMatrix*vec4(position, 1.0));
}
