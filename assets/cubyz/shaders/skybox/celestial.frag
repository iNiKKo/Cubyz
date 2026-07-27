#version 460

layout(location = 0) in vec2 unitPosition;
layout(location = 0) out vec4 fragColor;

layout(location = 5) uniform vec3 color;
layout(location = 6) uniform float opacity;

// Like smoothstep, but with linear interpolation instead of an s-curve (same idiom as Circle.frag).
float linearstep(float edge0, float edge1, float x) {
	return clamp((x - edge0)/(edge1 - edge0), 0.0, 1.0);
}

// Textureless soft-edged disc — same antialiasing trick as graphics/Circle.frag.
void main() {
	float dist = length(unitPosition);
	float delta = fwidth(dist)/2.0;
	float alpha = linearstep(1.0 + delta, 1.0 - delta, dist);
	fragColor = vec4(color, alpha*opacity);
}
