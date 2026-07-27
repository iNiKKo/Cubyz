#version 460

#include "frame_uniforms.glsl"

layout(location = 0) in vec2 inPos;

layout(location = 0) out vec2 localPos;

uniform float planeHeightRelative;

// The quad's local XY *is* already player-relative world XY (see thin_clouds.zig's planeHalfSize doc
// comment) — no playerPositionInteger/Fraction math needed here at all, only the height (uploaded
// already player-relative) and the camera's own view/projection from frame_uniforms.
void main() {
	vec3 position = vec3(inPos, planeHeightRelative);
	gl_Position = projectionMatrix*(viewMatrix*vec4(position, 1));
	localPos = inPos;
}
