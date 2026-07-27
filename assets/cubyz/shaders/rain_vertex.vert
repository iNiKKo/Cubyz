#version 460

#include "include/frame_uniforms.glsl"

layout(location = 0) in vec3 pos; // already player-relative (computed CPU-side, rebuilt every frame)

void main() {
	gl_Position = projectionMatrix*(viewMatrix*vec4(pos, 1));
}
