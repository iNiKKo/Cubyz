#version 460

layout(location = 0) in float brightness;
layout(location = 1) in float edgeFade;
layout(location = 2) in float cameraDistance;
layout(location = 0) out vec4 fragColor;

layout(location = 5) uniform vec3 tint;
layout(location = 6) uniform float baseAlpha;
uniform vec3 fogColor;
uniform float fogDensity;
uniform float weatherFogStrength;

void main() {
	vec3 color = tint*brightness;
	if (weatherFogStrength > 0.001) {

		float fogStart = mix(0.60, 0.35, weatherFogStrength)/max(1e-5, fogDensity);
		float fogAmount = max(0.0, cameraDistance - fogStart)*fogDensity*mix(8.0, 10.0, weatherFogStrength);
		fogAmount = mix(fogAmount, fogAmount*fogAmount, weatherFogStrength);
		color = mix(color, fogColor, 1.0 - exp(-fogAmount));
	}
	float alpha = baseAlpha*edgeFade;
	fragColor = vec4(color*alpha, alpha);
}
