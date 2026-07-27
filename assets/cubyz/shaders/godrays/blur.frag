#version 460

layout(location = 0) in vec2 texCoords;
layout(location = 0) out vec4 fragColor;

layout(binding = 3) uniform sampler2D maskColor;

uniform vec2 sunScreenPos; // texcoord-space ([0,1]) screen position of the sun/moon this frame
uniform float strength; // combined godRayIntensity * horizon-fade * screen-center-proximity fade

const int sampleCount = 32;
const float decay = 0.96;

// Interleaved gradient noise (Jorge Jimenez) — cheap, no texture lookup, breaks up the banding a fixed
// 32-tap geometric-decay march would otherwise show as visible rings radiating from the sun.
float ditherNoise(vec2 screenPos) {
	return fract(52.9829189*fract(dot(screenPos, vec2(0.06711056, 0.00583715))));
}

void main() {
	if (strength <= 0.0) {
		fragColor = vec4(0, 0, 0, 1);
		return;
	}

	vec2 delta = (sunScreenPos - texCoords)/float(sampleCount);
	float ditherOffset = ditherNoise(gl_FragCoord.xy);
	vec2 samplePos = texCoords + delta*ditherOffset;

	float accum = 0.0;
	float weight = 1.0;
	for (int i = 0; i < sampleCount; i++) {
		accum += texture(maskColor, samplePos).r*weight;
		samplePos += delta;
		weight *= decay;
	}
	accum /= float(sampleCount);

	fragColor = vec4(accum*strength, 0, 0, 1);
}
