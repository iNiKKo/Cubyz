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
// sparkle, which matters far more for how foliage shadows read. Cascade 1/2 stay tight since distant
// shadows are naturally soft anyway and don't show this artifact as strongly.
const float PCF_KERNEL_RADIUS_C0 = 2.0;  // cascade 0: wide enough to average out leaf/grass cutout noise
const float PCF_KERNEL_RADIUS_C1 = 1.2;  // cascade 1: smooth mid-range
const float PCF_KERNEL_RADIUS_C2 = 1.5;  // cascade 2: smooth far penumbra

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
float sampleCascadePCF(sampler2DShadow shadowMap, vec3 projCoords, float kernelRadius, int samples) {
	float angle = shadowKernelRotationAngle();
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
	float blockTopRelativeZ = worldPosRelative.z - fract(worldPosRelative.z + playerPositionFraction.z) + 1.0;
	vec3 shadowTestPos = isFoliage ? vec3(worldPosRelative.xy, blockTopRelativeZ) : worldPosRelative;
	// Normal-offset bias: offsets position outward along face normal to eliminate self-shadowing acne.
	// This applies to every non-foliage surface receiving a shadow, not just ground near grass — it's not
	// grass-specific, so shrinking it trades less peter-panning gap (previously computed at ~0.2-0.4
	// blocks at typical sun elevations, dominated by this term) for a higher chance of acne reappearing on
	// steep/grazing-angle terrain. Halved from 0.04 to 0.02 (2026-07-27) at the player's request after the
	// gap was still visible even with the depth-bias-in-blocks fix above; if speckled/noisy shadow
	// artifacts show up on steep hills or slanted terrain, raise this back up first before touching
	// biasBlocks again.
	const float normalOffsetBase = 0.02;
	vec3 offsetPos = isFoliage ? shadowTestPos : (worldPosRelative + normal * (normalOffsetBase * (1.0 + float(cascade) * 0.5)));
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

	if (cascade == 0) return sampleCascadePCF(csmMap0, projCoords, PCF_KERNEL_RADIUS_C0, 9);
	else if (cascade == 1) return sampleCascadePCF(csmMap1, projCoords, PCF_KERNEL_RADIUS_C1, 9);
	else return sampleCascadePCF(csmMap2, projCoords, PCF_KERNEL_RADIUS_C2, 4);
}

// Main sun/moon terrain shadow function. Returns a multiplier in [shadowAmbientFloor, 1.0]:
// 1.0 = fully lit, shadowAmbientFloor = fully in shadow.
// `isFoliage`: true for grass/plant quads (chunk_fragment.frag's opaqueInLod == 0). See below.
float sampleSunShadow(vec3 worldPosRelative, vec3 normal, float cameraDepth, bool isFoliage) {
	if (!shadowsEnabled) return 1.0;

	vec3 lightDir = normalize(sunDirection);
	float shadowAmbientFloor = isSunlight ? shadowAmbientFloorDay : shadowAmbientFloorNight;

	// Solid faces pointing away from or parallel to the sun (NdotL <= 0.001) receive ambient shadow floor
	// immediately without sampling the shadow map, preventing grazing-angle depth bias jitter on side faces:
	float NdotL = dot(normal, lightDir);
	if (!isFoliage && NdotL <= 0.001) return shadowAmbientFloor;

	// Select cascade by camera view depth:
	int cascade = 0;
	if (cameraDepth > csmCascadeFar[0]) cascade = 1;
	if (cameraDepth > csmCascadeFar[1]) cascade = 2;

	// Normal bias inputs, shared by every cascade this fragment samples:
	float absNdotL = max(abs(NdotL), 0.05);
	float sinTheta = sqrt(1.0 - clamp(absNdotL * absNdotL, 0.0, 1.0));
	float tanTheta = clamp(sinTheta / absNdotL, 0.0, 3.0);

	float light = sampleCascade(cascade, worldPosRelative, normal, tanTheta, isFoliage);

	// Cross-fade into the next cascade over the last stretch of this one's range:
	if (cascade < 2) {
		float boundary = csmCascadeFar[cascade];
		float blendWidth = boundary * 0.15;
		float blendStart = boundary - blendWidth;
		if (cameraDepth > blendStart) {
			float t = clamp((cameraDepth - blendStart)/blendWidth, 0.0, 1.0);
			float nextLight = sampleCascade(cascade + 1, worldPosRelative, normal, tanTheta, isFoliage);
			light = mix(light, nextLight, t);
		}
	}

	// Fade out shadow contrast near horizon so sunset/sunrise transition is silky smooth:
	float horizonFade = smoothstep(0.02, 0.18, abs(sunDirection.z));
	float finalShadow = mix(shadowAmbientFloor, 1.0, light);
	return mix(1.0, finalShadow, horizonFade);
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
