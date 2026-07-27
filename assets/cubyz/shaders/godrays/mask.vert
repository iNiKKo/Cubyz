#version 460

layout(location = 0) in vec2 inTexCoords;

layout(location = 0) out vec2 depthTexCoords;
layout(location = 1) out vec3 direction;
layout(location = 2) out vec2 screenUv;

layout(binding = 4) uniform sampler2D depthTexture;

layout(location = 0) uniform mat4 invViewMatrix;
layout(location = 1) uniform vec2 tanXY;

void main() {
	vec2 position = inTexCoords*2 - vec2(1, 1);
	direction = (invViewMatrix*vec4(position.x*tanXY.x, 1, position.y*tanXY.y, 0)).xyz;
	depthTexCoords = inTexCoords*textureSize(depthTexture, 0);
	screenUv = inTexCoords;
	gl_Position = vec4(position, 0, 1);
}
