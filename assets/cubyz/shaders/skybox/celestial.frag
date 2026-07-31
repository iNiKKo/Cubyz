#version 460

layout(location = 0) in vec2 unitPosition;
layout(location = 0) out vec4 fragColor;

layout(location = 5) uniform vec3 color;
layout(location = 6) uniform float opacity;
uniform float cloudAttenuation;

float linearstep(float edge0, float edge1, float x) {
	return clamp((x - edge0)/(edge1 - edge0), 0.0, 1.0);
}

void main() {
	float dist = length(unitPosition);
	float delta = fwidth(dist)/2.0;
	float alpha = linearstep(1.0 + delta, 1.0 - delta, dist);
	float cloudCover = clamp(1.0 - cloudAttenuation, 0.0, 1.0);

	float blurredDisc = linearstep(1.85 + delta, 1.85 - delta, dist);
	float blurredHalo = linearstep(2.75 + delta, 1.30 - delta, dist) * 0.16;
	float obscuredShape = blurredDisc*0.32 + blurredHalo;
	float rgbShape = mix(1.0, obscuredShape, cloudCover);

	fragColor = vec4(color*opacity*rgbShape, alpha*opacity);
}
