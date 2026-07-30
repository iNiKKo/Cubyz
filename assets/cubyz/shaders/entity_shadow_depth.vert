#version 460

layout(location = 0) in vec3 inPos;
layout(location = 2) in vec2 inUV;
layout(location = 3) in uint inNodeId;

layout(location = 0) out vec2 outTexCoord;

uniform mat4 lightSpaceMatrix;
uniform mat4 modelMatrix;
uniform uint nodeBufferOffset;

layout(std430, binding = 15) buffer _nodeMatrices
{
	mat4 nodeMatrices[];
};

void main() {
	outTexCoord = inUV;
	gl_Position = lightSpaceMatrix*modelMatrix*nodeMatrices[nodeBufferOffset + inNodeId]*vec4(inPos, 1.0);
}
