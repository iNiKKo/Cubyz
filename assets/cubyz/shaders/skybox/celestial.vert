#version 460

#include "../include/frame_uniforms.glsl"

layout(location = 0) in vec2 pos; // unit quad corner, -1..1

layout(location = 0) out vec2 unitPosition;

layout(location = 1) uniform vec3 worldCenter;
layout(location = 2) uniform vec3 billboardRight;
layout(location = 3) uniform vec3 billboardUp;
layout(location = 4) uniform float billboardSize;

// Sun/moon billboard: world-fixed orientation, perpendicular to the body's own direction — not
// camera-facing. billboardRight/Up are computed on the CPU from that direction alone (see
// renderer.zig Skybox.celestialBillboardBasis), so the disc doesn't rotate or distort as the player
// looks around; it only changes as the body moves through the day/night cycle.
void main() {
	unitPosition = pos;
	vec3 worldPos = worldCenter + billboardRight*pos.x*billboardSize + billboardUp*pos.y*billboardSize;
	gl_Position = projectionMatrix*(viewMatrix*vec4(worldPos, 1));
}
