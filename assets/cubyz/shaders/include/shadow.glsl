// Sun/moon shadow: Cascaded Shadow Maps (CSM) with 9-tap Poisson-disk PCF.
//
// Three cascades cover progressively wider view-depth ranges — close geometry gets a sharp,
// high-resolution shadow, far geometry gets a wider, naturally softer one. Each cascade is
// rendered as a depth-only texture from the sun/moon's perspective (see shadow_depth.vert/.frag
// and renderer.zig's CascadedShadowMap). Hardware sampler2DShadow provides free bilinear PCF
// interpolation between depth comparisons, giving smooth penumbra gradients that were impossible
// with the previous binary voxel DDA approach.

// CSM depth textures — each is a depth-only FBO texture set up with GL_COMPARE_REF_TO_TEXTURE
// so the hardware returns a filtered 0..1 shadow value directly from texture().
layout(binding = 6) uniform sampler2DShadow csmMap0; // cascade 0: 0..24 blocks
layout(binding = 7) uniform sampler2DShadow csmMap1; // cascade 1: 24..96 blocks
layout(binding = 8) uniform sampler2DShadow csmMap2; // cascade 2: 96..shadowDistance blocks

// Light-space VP matrices (one per cascade) — transforms player-relative world coords into
// the cascade's [−1,1]³ clip space, which we then remap to [0,1]³ UV + depth.
layout(location = 44) uniform mat4 csmLightSpaceMatrix[3];
// View-space depth at which each cascade ends (where the next cascade takes over).
layout(location = 47) uniform float csmCascadeFar[3];  // {24, 96, shadowDistance}
// Resolution of each cascade's depth texture in texels (square).
layout(location = 50) uniform float csmTexelSize;       // 1.0 / shadowMapSize

// Shared uniforms (explicit locations to avoid collisions with chunk_vertex.vert's locations 0-14):
layout(location = 33) uniform bool shadowsEnabled;
layout(location = 38) uniform bool isSunlight; // false when moonlight is casting the shadow
layout(location = 37) uniform vec3 sunDirection; // direction *toward* the sun/moon
layout(location = 39) uniform float shadowDarkness; // [0.0, 1.0] shadow darkness factor
// [0,1]: 1.0 = normal shadow contrast, 0.0 = faded to fully-lit right at the sun/moon crossing (see
// DayTime.getShadowTransitionFade's doc comment for why this exists — the crossing's instantaneous
// direction flip needs hiding, and the pre-existing horizonFade below can't do it since sunDirection is
// already elevation-clamped by the time it reaches this shader, keeping abs(sunDirection.z) well outside
// horizonFade's window even exactly at the crossing).
layout(location = 51) uniform float shadowTransitionFade;
// How many cascades actually got a fresh depth-map render/light-space matrix this session — driven by
// settings.shadowDistance (renderer.zig's CascadedShadowMap.update, "activeCascades"). At low
// shadowDistance settings only cascade 0 (sometimes 0-1) is genuinely active; csmMap1/csmMap2's textures
// and csmLightSpaceMatrix[1]/[2] are left stale/uninitialized in that case, NOT continuously updated —
// sampleSunShadow's cross-cascade blend must never sample a cascade >= this count, or it mixes in
// garbage from a stale light-space projection right at the edge of the lowest active cascade. This was
// the actual cause of a player-reported "close-range leaf shadows look noisy" bug that only appeared at
// low Dynamic Shadow Distance settings — narrowed down by the player noticing it scaled with that
// specific slider, not shadow quality/resolution as first assumed.
layout(location = 52) uniform int csmActiveCascades;
// These cloud uniforms kept at same locations as before to avoid having to change bindCommonUniforms:
layout(location = 34) uniform vec2 cloudCoverageOrigin;
layout(location = 35) uniform float cloudCoverageWorldSize;
layout(location = 36) uniform float cloudHeightRelative;

const float shadowAmbientFloorDay = 0.55;
const float shadowAmbientFloorNight = 0.78;

// 9-tap Poisson disk offsets (radius ≈ 1.0). Generated to give good coverage without clustering.
const vec2 poissonDisk[9] = vec2[](
	vec2( 0.000,  0.000), // centre
	vec2( 0.916, -0.398),
	vec2( 0.015, -0.917),
	vec2(-0.827,  0.564),
	vec2(-0.360,  0.933),
	vec2(-0.913, -0.359),
	vec2( 0.408,  0.910),
	vec2( 0.765,  0.644),
	vec2(-0.545, -0.723)
);

const int PCF_SAMPLES = 9;

// How wide the PCF filter kernel spreads, in texels.
// Cascade 0 is intentionally wider than a "just eliminate sample noise" radius would need: alpha-cutout
// leaf/grass edges in the shadow depth map flip individual texels between "hole" and "solid" as the sun
// direction slowly changes over the day (and as the camera moves the frustum by whole texels), which
// reads as a fine sparkling noise on tree/foliage shadows specifically at close range. Averaging over a
// wider footprint here trades a little bit of contact-shadow sharpness on solid blocks for killing that
// sparkle, which matters far more for how foliage shadows read.
//
// Cascade 2's old assumption ("distant shadows are naturally soft anyway and don't show this artifact as
// strongly") turned out to be backwards for foliage specifically — player-reported "shadow on leaves from
// afar look noisy/pulsing... some too dark, some not dark at all." Cascade 2 covers a much larger
// world-space area per shadow-map texel than cascade 0 (coarser effective resolution), so each texel
// represents a bigger chunk of a tree's leaf-cutout pattern — the alpha-cutout noise doesn't get smaller/
// softer at distance, it gets COARSER (larger, blockier noise clumps), and a narrow 4-tap kernel was
// nowhere near wide/dense enough to average that out, unlike cascade 0's deliberately wide 9-tap
// treatment for the same underlying problem at close range. Widened + upgraded to the full 9-tap kernel
// (was 4-tap) so distant foliage gets the same "blend the alpha-cutout noise into a soft, stable shadow
// instead of a noisy/pulsing one" treatment cascade 0 already has, rather than the opposite.
const float PCF_KERNEL_RADIUS_C0 = 2.0;  // cascade 0: wide enough to average out leaf/grass cutout noise
const float PCF_KERNEL_RADIUS_C1 = 1.2;  // cascade 1: smooth mid-range
const float PCF_KERNEL_RADIUS_C2 = 3.5;  // cascade 2: wide enough for distant foliage's coarser cutout noise

// Per-fragment interleaved-gradient-noise angle, used to rotate the Poisson disk so its sample pattern
// isn't screen-aligned. Without this, the fixed sample directions can beat against the shadow map's own
// texel grid and leaf/grass cutout pattern into a coherent, structured shimmer; rotating the kernel
// per-pixel turns that structured aliasing into unstructured (much less noticeable) noise instead.
float shadowKernelRotationAngle() {
	vec2 uv = gl_FragCoord.xy;
	float n = fract(52.9829189 * fract(dot(uv, vec2(0.06711056, 0.00583715))));
	return n * 6.2831853;
}

// 4-tap Poisson disk for distant Cascade 2 (fast & smooth far shadows):
const vec2 poissonDiskFar[4] = vec2[](
	vec2(-0.360,  0.933),
	vec2( 0.408,  0.910),
	vec2( 0.765, -0.644),
	vec2(-0.545, -0.723)
);

// Sample the given cascade shadow map with a Poisson-disk PCF kernel.
// projCoords: [0,1]³ UV.xy + reference depth .z (with normal bias already applied)
// kernelRadius: PCF spread in texels
// noRotation: skips the per-pixel kernel rotation (see below) for foliage self-shadowing specifically.
float sampleCascadePCF(sampler2DShadow shadowMap, vec3 projCoords, float kernelRadius, int samples, bool noRotation) {
	// shadowKernelRotationAngle is a function of gl_FragCoord ALONE — the same screen pixel gets the
	// exact same rotation angle every single frame, forever (no time/frame dependence at all). For
	// ordinary solid-ground shadows this successfully turns texel-grid shimmer into unstructured noise
	// (its intended purpose) — but foliage self-shadowing (leaf-on-leaf occlusion within a canopy) has
	// much higher per-texel contrast than ground shadows do, and a FIXED per-pixel rotation pattern
	// applied to that high-contrast signal becomes visible as its own static, regular dot pattern baked
	// onto the screen — player-reported "screen-door effect... like a CRT filter," worse up close
	// (cascade 0's higher resolution/larger on-screen size makes the fixed pattern more visible, not the
	// rotation itself behaving differently there). Foliage samples skip the rotation entirely instead —
	// an unrotated kernel has no fixed-orientation grid-aliasing risk against the *screen*, only against
	// the shadow map's own texel grid, which cascade 0's separately-widened kernel radius (see
	// PCF_KERNEL_RADIUS_C0) already exists to blur past — trading "rotate to fight one artifact" for
	// "rely on a wide kernel to fight it instead," since the rotation was the thing causing THIS artifact.
	float angle = noRotation ? 0.0 : shadowKernelRotationAngle();
	float s = sin(angle);
	float cAngle = cos(angle);
	float shadow = 0.0;
	if (samples <= 4) {
		for (int i = 0; i < 4; ++i) {
			vec2 diskPoint = poissonDiskFar[i];
			vec2 offset = vec2(diskPoint.x*cAngle - diskPoint.y*s, diskPoint.x*s + diskPoint.y*cAngle) * kernelRadius * csmTexelSize;
			shadow += texture(shadowMap, vec3(projCoords.xy + offset, projCoords.z));
		}
		return shadow * 0.25;
	} else {
		for (int i = 0; i < 9; ++i) {
			vec2 diskPoint = poissonDisk[i];
			vec2 offset = vec2(diskPoint.x*cAngle - diskPoint.y*s, diskPoint.x*s + diskPoint.y*cAngle) * kernelRadius * csmTexelSize;
			shadow += texture(shadowMap, vec3(projCoords.xy + offset, projCoords.z));
		}
		return shadow / 9.0;
	}
}

// Samples one cascade's PCF shadow value for a given world position, including its own normal bias.
// Returns 1.0 (unshadowed) for fragments that fall outside that cascade's projection — the caller is
// responsible for only trusting that result when it knows the position should actually be covered.
float sampleCascade(int cascade, vec3 worldPosRelative, vec3 normal, float tanTheta, bool isFoliage) {
	// Foliage (grass/plants) is a cross of two *vertical* planes spanning its block from z=0 to z=1
	// (see cross.obj), and it writes into the shadow map itself. That makes any sample point taken
	// partway up a blade sit *underneath the blade's own geometry*: the ray from there toward the sun
	// passes straight through the rest of the cross, so the blade shadows itself. That self-occlusion is
	// what reads as a hard, detached-looking band on the tuft, and because each fragment sampled at its
	// own height, the band also parallaxed across the blade as the sun moved.
	//
	// Sampling at the *top* of the foliage's block instead removes the problem at its source: from there
	// the entire cross is below the sample point, so nothing of its own can occlude it, while a real
	// external caster (wall, tree, terrain) one block up still registers essentially identically. Vertical
	// shading variation across the blade then comes from the root-AO gradient in chunk_fragment.frag,
	// which is stable, rather than from a self-shadow that swings around with the sun.
	//
	// worldPosRelative is relative to the player's continuously-moving position (chunk_vertex.vert:
	// blockPos - playerPositionInteger - playerPositionFraction), so snapping on it directly would land
	// on a different plane depending on the player's own sub-block Z offset — flickering while
	// jumping/moving even though the grass never moves. Adding playerPositionFraction.z back inside
	// fract() cancels that term, so the snap only depends on the fragment's true world position.
	//
	// A floor-level second sample (to catch "grass glowing next to a shadowed block behind it") was tried
	// and reverted twice (2026-07-27): first using the fragment's own X/Y (panels of one tuft disagreed
	// with each other), then using the block center (both of cross.obj's diagonal panels pass through
	// (0.5, 0.5) simultaneously, so the floor test self-occluded against the plant's own geometry almost
	// always — all grass went dark and flickered). The player asked to revert to this known-good state
	// rather than keep iterating; if the glow issue is revisited, don't repeat either of those two
	// approaches — see the item in memory.md for what was tried and ruled out.
	// isFoliage is also true for solid, axis-aligned cube-shaped leaf blocks (assets/cubyz/models/
	// cube_leaf.obj, opted in via cube_leaf.zig.zon so the "Foliage Sway" wind animation applies to
	// them) — NOT just thin cross-quad plants (cross.obj) this block-top snap was designed and verified
	// for. A leaf block spans a full solid cube, not a single thin plane through the whole block height,
	// so unlike grass it has no analogous self-occlusion problem to correct for; applying this snap to it
	// anyway produced a rapid shadow flicker specifically under vertical player movement, since
	// worldPosRelative.z legitimately varies fragment-to-fragment across a stacked, multi-block-tall
	// canopy in a way it never does across one grass block. cross.obj's blade quads have diagonal
	// (+-0.707, +-0.707, 0) normals; cube_leaf.obj (like any ordinary cube face) has axis-aligned normals
	// — cheap, reliable, purely-geometric way to tell "thin cross-quad plant that needs this snap" apart
	// from "solid cube-shaped foliage that doesn't," with no new per-quad data needed.
	bool isCrossQuadFoliage = isFoliage && abs(normal.z) < 0.9;
	float blockTopRelativeZ = worldPosRelative.z - fract(worldPosRelative.z + playerPositionFraction.z) + 1.0;
	vec3 shadowTestPos = isCrossQuadFoliage ? vec3(worldPosRelative.xy, blockTopRelativeZ) : worldPosRelative;
	// Normal-offset bias: offsets position outward along face normal to eliminate self-shadowing acne.
	// This applies to every non-foliage surface receiving a shadow, not just ground near grass — it's not
	// grass-specific, so shrinking it trades less peter-panning gap (previously computed at ~0.2-0.4
	// blocks at typical sun elevations, dominated by this term) for a higher chance of acne reappearing on
	// steep/grazing-angle terrain. Halved from 0.04 to 0.02 (2026-07-27) at the player's request after the
	// gap was still visible even with the depth-bias-in-blocks fix above; if speckled/noisy shadow
	// artifacts show up on steep hills or slanted terrain, raise this back up first before touching
	// biasBlocks again.
	const float normalOffsetBase = 0.02;
	// Gated on isCrossQuadFoliage (not the raw isFoliage) for the same reason as shadowTestPos above —
	// solid cube-shaped leaf blocks should get the ordinary normal-offset acne bias like any other solid
	// surface, not skip it the way thin cross-quad plants correctly do.
	vec3 offsetPos = isCrossQuadFoliage ? shadowTestPos : (worldPosRelative + normal * (normalOffsetBase * (1.0 + float(cascade) * 0.5)));
	vec4 lightSpacePos = csmLightSpaceMatrix[cascade] * vec4(offsetPos, 1.0);
	vec3 projCoords = lightSpacePos.xyz / lightSpacePos.w;
	projCoords = projCoords * 0.5 + 0.5; // clip [-1,1] → UV [0,1]

	if (any(lessThan(projCoords, vec3(0.001))) || any(greaterThan(projCoords, vec3(0.999)))) {
		return 1.0; // outside cascade coverage (XY or Z): treat as unshadowed
	}

	// `projCoords.z` is normalized [0,1] across this cascade's *orthographic depth range*, and that range
	// is very different per cascade: renderer.zig's computeLightSpaceMatrix builds it as
	// (2*radius + zMargin + 32) with zMargin = 256, giving 336 / 480 / 1312 blocks for cascades 0/1/2.
	// A single normalized bias constant therefore meant wildly different *world-space* biases —
	// 0.13 / 0.96 / 2.62 blocks — and world-space depth bias is precisely what detaches a shadow from the
	// thing casting it: the lit gap it opens on the ground is biasBlocks / tan(sunElevation), so at a low
	// sun a 0.13-block bias became a ~0.5-block gap (and cascade 2's became several blocks). Specifying
	// the bias in blocks and converting here makes it mean the same small distance in every cascade.
	// KEEP IN SYNC with renderer.zig computeLightSpaceMatrix: zMargin (1024.0) + far margin (32.0) = 1056.0.
	float cascadeDepthRange = 2.0*csmCascadeFar[cascade] + (cascade == 0 ? 128.0 : (cascade == 1 ? 288.0 : 1056.0));
	float biasBlocks = mix(0.010, 0.030, clamp(tanTheta/3.0, 0.0, 1.0)); // slope-scaled, in blocks
	float bias = biasBlocks/max(cascadeDepthRange, 1.0);
	projCoords.z -= bias;

	// Foliage self-shadowing (leaf-on-leaf occlusion within a canopy) skips the per-pixel kernel rotation
	// entirely — see sampleCascadePCF's own doc comment for why (a fixed rotation pattern applied to
	// foliage's high-contrast alpha-cutout signal reads as a static screen-space dot pattern, "screen-door
	// effect"). Widened slightly (*1.4) alongside dropping the rotation: the rotation was doing some of
	// the "spread samples out" work a fixed kernel orientation alone doesn't, so a small radius bump keeps
	// foliage shadows at least as smooth as before, just without the fixed-pattern artifact.
	float foliageKernelBoost = isFoliage ? 1.4 : 1.0;
	if (cascade == 0) return sampleCascadePCF(csmMap0, projCoords, PCF_KERNEL_RADIUS_C0 * foliageKernelBoost, 9, isFoliage);
	else if (cascade == 1) return sampleCascadePCF(csmMap1, projCoords, PCF_KERNEL_RADIUS_C1 * foliageKernelBoost, 9, isFoliage);
	// Was 4 (the coarse poissonDiskFar set) — upgraded to the full 9-tap kernel, matching cascades 0/1,
	// per PCF_KERNEL_RADIUS_C2's own updated doc comment above (distant foliage needs MORE filtering to
	// average out its coarser alpha-cutout noise, not less).
	else return sampleCascadePCF(csmMap2, projCoords, PCF_KERNEL_RADIUS_C2 * foliageKernelBoost, 9, isFoliage);
}

// Main sun/moon terrain shadow function. Returns a multiplier in [shadowAmbientFloor, 1.0]:
// 1.0 = fully lit, shadowAmbientFloor = fully in shadow.
// `isFoliage`: true for grass/plant quads (chunk_fragment.frag's opaqueInLod == 0). See below.
float sampleSunShadow(vec3 worldPosRelative, vec3 normal, float cameraDepth, bool isFoliage) {
	if (!shadowsEnabled) return 1.0;

	vec3 lightDir = normalize(sunDirection);
	float baseAmbientFloor = isSunlight ? shadowAmbientFloorDay : shadowAmbientFloorNight;
	float shadowAmbientFloor = (shadowDarkness <= 0.5)
		? mix(1.0, baseAmbientFloor, shadowDarkness * 2.0)
		: mix(baseAmbientFloor, baseAmbientFloor * 0.2, (shadowDarkness - 0.5) * 2.0);

	// isFoliage is true both for thin cross-quad plants (cross.obj — grass, flowers) AND solid,
	// axis-aligned cube-shaped leaf blocks (cube_leaf.obj, opted in only so the "Foliage Sway" wind
	// animation applies — see sampleCascade's own doc comment for the full story and why this caused a
	// rapid shadow flicker on leaves specifically under vertical movement). Only the former actually needs
	// this function's foliage-specific self-occlusion handling; a solid cube's back face pointing away
	// from the sun is exactly the ordinary "skip the shadow map, use the ambient floor" case every other
	// solid block already gets. isCrossQuadFoliage re-derives the same cheap geometric test
	// sampleCascade uses (diagonal cross.obj normals vs. axis-aligned cube normals) so this function's
	// decisions and sampleCascade's stay consistent without needing a second flag threaded through the
	// whole vertex->fragment pipeline.
	bool isCrossQuadFoliage = isFoliage && abs(normal.z) < 0.9;

	// Solid faces pointing away from or parallel to the sun (NdotL <= 0.001) receive ambient shadow floor
	// immediately without sampling the shadow map, preventing grazing-angle depth bias jitter on side faces:
	float NdotL = dot(normal, lightDir);
	if (!isCrossQuadFoliage && NdotL <= 0.001) return shadowAmbientFloor;

	// Select cascade by camera view depth, clamped to the highest cascade that's actually active this
	// session (see csmActiveCascades' own doc comment) — a fragment beyond the active range would
	// otherwise select an inactive cascade as its PRIMARY sample (not just the cross-cascade blend
	// fixed above), sampling a stale/never-rendered csmMap+csmLightSpaceMatrix the exact same way.
	int cascade = 0;
	if (cameraDepth > csmCascadeFar[0]) cascade = 1;
	if (cameraDepth > csmCascadeFar[1]) cascade = 2;
	cascade = min(cascade, csmActiveCascades - 1);

	// Normal bias inputs, shared by every cascade this fragment samples:
	float absNdotL = max(abs(NdotL), 0.05);
	float sinTheta = sqrt(1.0 - clamp(absNdotL * absNdotL, 0.0, 1.0));
	float tanTheta = clamp(sinTheta / absNdotL, 0.0, 3.0);

	float light = sampleCascade(cascade, worldPosRelative, normal, tanTheta, isFoliage);

	// Cross-fade into the next cascade over the last stretch of this one's range — but only if that next
	// cascade is actually active this session (see csmActiveCascades' own doc comment above). Blending
	// into an inactive cascade means sampling csmMap[cascade+1] against a stale/never-computed
	// csmLightSpaceMatrix[cascade+1], which is exactly what produced the player-reported close-range leaf
	// shadow noise at low Dynamic Shadow Distance settings (that setting drops csmActiveCascades to 1,
	// making this guard the actual fix — not a PCF/filtering change, which was tried first and mistargeted
	// cascade 2 instead of this).
	if (cascade < 2 && cascade + 1 < csmActiveCascades) {
		float boundary = csmCascadeFar[cascade];
		float blendWidth = boundary * 0.15;
		float blendStart = boundary - blendWidth;
		if (cameraDepth > blendStart) {
			float t = clamp((cameraDepth - blendStart)/blendWidth, 0.0, 1.0);
			float nextLight = sampleCascade(cascade + 1, worldPosRelative, normal, tanTheta, isFoliage);
			light = mix(light, nextLight, t);
		}
	}

	// Fade out shadow contrast near horizon so sunset/sunrise transition is silky smooth. NOTE:
	// sunDirection here is already elevation-clamped (>= 0.35, see DayTime.getShadowLightDirection), so
	// this horizonFade term alone can never actually reach 0 — it's kept for whatever residual smoothing
	// it still provides at low-but-not-clamped elevations, but shadowTransitionFade (below) is the term
	// that actually hides the sun/moon crossing's instantaneous direction flip.
	float horizonFade = smoothstep(0.02, 0.18, abs(sunDirection.z));
	float finalShadow = mix(shadowAmbientFloor, 1.0, light);
	finalShadow = mix(1.0, finalShadow, horizonFade);
	return mix(1.0, finalShadow, shadowTransitionFade);
}

// MARK: cloud shadows

layout(binding = 9) uniform sampler2D cloudCoverageTex;
const float cloudShadowStrength = 0.3;

float sampleCloudShadow(vec3 worldPosRelative) {
	if (!shadowsEnabled) return 1.0;
	if (sunDirection.z <= 0.001) return 1.0; // Sun/moon below the horizon: no cast shadow either way.

	// Where does the ray from this fragment toward the sun cross the cloud layer's height?
	float t = (cloudHeightRelative - worldPosRelative.z)/sunDirection.z;
	if (t <= 0.0) return 1.0; // Cloud layer is behind the fragment.

	vec2 samplePos = worldPosRelative.xy + sunDirection.xy*t;
	vec2 uv = (samplePos - cloudCoverageOrigin)/cloudCoverageWorldSize;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return 1.0;

	// At low sun angles this ray can travel a very long way horizontally before it reaches the cloud
	// layer, so the cloud cell actually responsible for a given ground shadow can sit far outside what
	// the player is anywhere near or looking at (easily hundreds of blocks away, near the edge of the
	// whole coverage grid) — that reads as cloud shadows appearing "randomly"/disconnected from any
	// visible cloud. Fading shadow strength out with the *sampled cloud position's* distance from the
	// player (not the shadowed fragment's) keeps only reasonably nearby clouds able to cast a visible
	// shadow, well before the grid's own hard edge.
	float distFromPlayer = length(samplePos);
	float halfExtent = cloudCoverageWorldSize*0.5;
	float distanceFade = 1.0 - smoothstep(halfExtent*0.4, halfExtent*0.9, distFromPlayer);

	float coverage = texture(cloudCoverageTex, uv).r;
	float shadow = 1.0 - smoothstep(0.45, 0.65, coverage)*cloudShadowStrength*distanceFade;
	return shadow;
}
