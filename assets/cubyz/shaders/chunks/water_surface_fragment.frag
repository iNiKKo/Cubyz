#version 460

#include "frame_uniforms.glsl"

layout(location = 3) in vec2 uv;
layout(location = 4) flat in vec3 normal;
layout(location = 5) flat in int textureIndex;
layout(location = 11) in vec3 worldPos;

layout(location = 0) out vec4 fragColor;

layout(binding = 0) uniform sampler2DArray textureSampler;
layout(std430, binding = 1) buffer _animatedTexture {
	float animatedTexture[];
};
uniform int waterTextureIndex;

void main() {
	// The mesh emits a top quad only where water meets air. Draw it from either winding because this is
	// an explicit interior-facing mask, not the ordinary one-sided transparent water appearance.
	if (textureIndex != waterTextureIndex || normal.z < 0.9) discard;
	float playerWorldZ = float(playerPositionInteger.z) + playerPositionFraction.z;
	if (worldPos.z <= playerWorldZ + 0.05) discard;

	float depthToSurface = worldPos.z - playerWorldZ;
	float proximity = exp(-depthToSurface*0.08);
	// Match renderer.zig's 72-block submerged mesh cap. The surface must disappear into the water
	// atmosphere before the cap instead of ending on the exact square outline of the last submitted chunk.
	vec2 playerWorldXY = vec2(float(playerPositionInteger.x), float(playerPositionInteger.y)) + playerPositionFraction.xy;
	float capFade = 1.0 - smoothstep(42.0, 68.0, length(worldPos.xy - playerWorldXY));
	// World-space coordinates keep the underside pattern continuous across neighbouring blocks. The
	// animated layer is still the normal water animation, so the surface retains the existing water motion.
	vec3 pattern = texture(textureSampler, vec3(worldPos.xy*0.18, animatedTexture[textureIndex])).rgb;
	// This is an orientation cue through water, not an opaque second sky. Keep the texture subdued and
	// let the existing underwater fog remain visible through it; only close to the surface does it become
	// pronounced enough to clearly mark the route to air.
	vec3 colour = pattern*0.24 + vec3(0.028, 0.115, 0.20)*(0.30 + 0.70*proximity);
	float alpha = mix(0.30, 0.58, proximity)*capFade;
	fragColor = vec4(colour*alpha, alpha);
}
