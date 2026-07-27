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

// Sample the given cascade shadow map with a Poisson-disk PCF kernel.
// projCoords: [0,1]³ UV.xy + reference depth .z (with normal bias already applied)
// kernelRadius: PCF spread in texels
float sampleCascadePCF(sampler2DShadow shadowMap, vec3 projCoords, float kernelRadius) {
	float angle = shadowKernelRotationAngle();
	float s = sin(angle);
	float cAngle = cos(angle);
	float shadow = 0.0;
	for (int i = 0; i < PCF_SAMPLES; ++i) {
		vec2 diskPoint = poissonDisk[i];
		vec2 rotated = vec2(diskPoint.x*cAngle - diskPoint.y*s, diskPoint.x*s + diskPoint.y*cAngle);
		vec2 offset = rotated * kernelRadius * csmTexelSize;
		shadow += texture(shadowMap, vec3(projCoords.xy + offset, projCoords.z));
	}
	return shadow / float(PCF_SAMPLES);
}

// Samples one cascade's PCF shadow value for a given world position, including its own normal bias.
// Returns 1.0 (unshadowed) for fragments that fall outside that cascade's projection — the caller is
// responsible for only trusting that result when it knows the position should actually be covered.
float sampleCascade(int cascade, vec3 worldPosRelative, vec3 normal, float tanTheta, bool isFoliage) {
	// Normal-offset bias: offsets position outward along face normal to eliminate self-shadowing acne
	vec3 offsetPos = isFoliage ? worldPosRelative : (worldPosRelative + normal * (0.04 * (1.0 + float(cascade) * 0.5)));
	vec4 lightSpacePos = csmLightSpaceMatrix[cascade] * vec4(offsetPos, 1.0);
	vec3 projCoords = lightSpacePos.xyz / lightSpacePos.w;
	projCoords = projCoords * 0.5 + 0.5; // clip [-1,1] → UV [0,1]

	if (any(lessThan(projCoords.xy, vec2(0.001))) || any(greaterThan(projCoords.xy, vec2(0.999)))) {
		return 1.0; // outside cascade coverage: treat as unshadowed
	}

	float cascadeBiasScale = 1.0 + float(cascade) * 1.5;
	float bias = (cascade == 0) ? clamp(0.0001 * tanTheta, 0.00005, 0.0004) : clamp(0.0003 * tanTheta * cascadeBiasScale, 0.0002, 0.002);
	projCoords.z -= bias;

	if (cascade == 0) return sampleCascadePCF(csmMap0, projCoords, PCF_KERNEL_RADIUS_C0);
	else if (cascade == 1) return sampleCascadePCF(csmMap1, projCoords, PCF_KERNEL_RADIUS_C1);
	else return sampleCascadePCF(csmMap2, projCoords, PCF_KERNEL_RADIUS_C2);
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

	// Soft, subtle self-shadowing on foliage (blends 60% toward 1.0 unshadowed so plant blades have 3D depth without turning dark):
	if (isFoliage) {
		light = mix(light, 1.0, 0.60);
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
