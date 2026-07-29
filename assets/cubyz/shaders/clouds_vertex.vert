#version 460

#include "include/frame_uniforms.glsl"

layout(location = 0) in vec3 pos;
layout(location = 1) in float brightness;
layout(location = 2) in float edgeFade;

uniform vec3 meshOriginRelative;

layout(location = 0) out float outBrightness;
layout(location = 1) out float outEdgeFade;
layout(location = 2) out float outCameraDistance;

void main() {
	outBrightness = brightness;
	outEdgeFade = edgeFade;
	vec3 relativePosition = pos + meshOriginRelative;
	outCameraDistance = length(relativePosition);
	gl_Position = projectionMatrix*(viewMatrix*vec4(relativePosition, 1.0));
}
