#version 460

#include "include/frame_uniforms.glsl"

layout(location = 0) in vec3 pos;
layout(location = 1) in float brightness;
layout(location = 2) in float edgeFade;

layout(location = 0) out float outBrightness;
layout(location = 1) out float outEdgeFade;

void main() {
	outBrightness = brightness;
	outEdgeFade = edgeFade;
	gl_Position = projectionMatrix*(viewMatrix*vec4(pos, 1));
}
