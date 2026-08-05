#version 460

layout(location = 0) in vec3 mvVertexPos;
layout(location = 1) in flat int axisIndex;

layout(location = 0) out vec4 fragColor;

layout(location = 5) uniform int hoveredAxis;
layout(location = 6) uniform int grabbedAxis;
layout(location = 7) uniform int errorActive;
layout(location = 8) uniform float flashPhase;

vec3 axisColor[] = vec3[] (
	vec3(1, 0.15, 0.15),
	vec3(0.15, 1, 0.15),
	vec3(0.25, 0.45, 1)
);

const vec3 hoverColor = vec3(1.0, 0.55, 0.12);
const vec3 grabColor = vec3(1.0, 0.84, 0.25);
const vec3 errorColor = vec3(1.0, 0.24, 0.08);

void main() {
	vec3 color = axisColor[axisIndex];

	if (errorActive == 1 && axisIndex == grabbedAxis) {
		float flash = 0.4 + 0.6*sin(flashPhase*18.0);
		color = mix(color, errorColor, flash);
	} else if (axisIndex == grabbedAxis) {
		float glow = 0.7 + 0.3*sin(flashPhase*10.0);
		color = mix(color, grabColor, glow);
	} else if (axisIndex == hoveredAxis) {
		float blink = 0.5 + 0.5*sin(flashPhase*16.0);
		color = mix(color, hoverColor, 0.45 + 0.45*blink);
	}

	fragColor = vec4(color, 1);
}
