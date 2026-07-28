#version 460

layout(location = 0) in float brightness;
layout(location = 1) in float edgeFade;
layout(location = 0) out vec4 fragColor;

layout(location = 5) uniform vec3 tint;
layout(location = 6) uniform float baseAlpha;

void main() {
	fragColor = vec4(tint*brightness, baseAlpha*edgeFade);
}
