#version 460

#include "frame_uniforms.glsl"

layout(location = 0) in vec3 mvVertexPos;
layout(location = 1) in vec3 direction;
layout(location = 2) in vec3 light;
layout(location = 3) in vec2 uv;
layout(location = 4) flat in vec3 normal;
layout(location = 5) flat in int textureIndex;
layout(location = 6) flat in int isBackFace;
layout(location = 7) flat in float distanceForLodCheck;
layout(location = 8) flat in int opaqueInLod;
layout(location = 11) in vec3 worldPos;

layout(location = 0, index = 0) out vec4 fragColor;
layout(location = 0, index = 1) out vec4 blendColor;

layout(binding = 0) uniform sampler2DArray textureSampler;
layout(binding = 1) uniform sampler2DArray emissionSampler;
layout(binding = 2) uniform sampler2DArray reflectivityAndAbsorptionSampler;
layout(binding = 3) uniform sampler2D worldColorSampler;
layout(binding = 4) uniform samplerCube reflectionMap;
layout(binding = 5) uniform sampler2D depthTexture;

layout(location = 5) uniform float reflectionMapSize;
layout(location = 6) uniform float contrast;

layout(location = 8) uniform float zNear;
layout(location = 9) uniform float zFar;

uniform bool reflectionsEnabled;
// Texture-handle identity, supplied by the block registry. Transparency and material reflectivity
// are deliberately not used as water tests: ice, glass, and transparent foliage must stay still.
uniform int waterTextureIndex;
// Matches deferred-render terrain weather fog. This is deliberately explicit rather than inferred
// from density, since ordinary short render-distance fog must not make clear-weather lakes opaque.
uniform float weatherFogStrength;
// Real elapsed seconds, for the water-reflection ripple below — see chunk_meshing.zig's
// bindTransparentShaderAndUniforms (same pattern clouds.zig/thin_clouds.zig use for wind animation).
uniform float waterTime;

struct Fog {
	vec3 color;
	float density;
	float fogLower;
	float fogHigher;
};

layout(location = 10) uniform Fog fog;

layout(std430, binding = 1) buffer _animatedTexture
{
	float animatedTexture[];
};

struct FogData {
	float fogDensity;
	uint fogColor;
};

layout(std430, binding = 7) buffer _fogData
{
	FogData fogData[];
};

#include "shadow.glsl"

float lightVariation(vec3 normal) {
	const vec3 directionalPart = vec3(0, contrast/2, contrast);
	const float baseLighting = 1 - contrast;
	return baseLighting + dot(normal, directionalPart);
}

vec3 unpackColor(uint color) {
	return vec3(
		color>>16 & 255u,
		color>>8 & 255u,
		color & 255u
	)/255.0;
}

float zFromDepth(float depthBufferValue) {
	return zNear*zFar/(depthBufferValue*(zNear - zFar) + zFar);
}

float densityIntegral(float dist, float zStart, float zDist, float fogLower, float fogHigher) {
	// The density is constant until fogLower, then gets smaller linearly until reaching fogHigher, past which there is no fog.
	if(zDist < 0) {
		zStart += zDist;
		zDist = -zDist;
	}
	if(abs(zDist) < 0.001) {
		zDist = 0.001;
	}
	float beginLower = min(fogLower, zStart);
	float endLower = min(fogLower, zStart + zDist);
	float beginMid = max(fogLower, min(fogHigher, zStart));
	float endMid = max(fogLower, min(fogHigher, zStart + zDist));
	float midIntegral = -0.5*(endMid - fogHigher)*(endMid - fogHigher)/(fogHigher - fogLower) - -0.5*(beginMid - fogHigher)*(beginMid - fogHigher)/(fogHigher - fogLower);
	if(fogHigher == fogLower) midIntegral = 0;

	return (endLower - beginLower + midIntegral)/zDist*dist;
}

float calculateFogDistance(float dist, float densityAdjustment, float zStart, float zScale, float fogDensity, float fogLower, float fogHigher) {
	float distCameraTerrain = densityIntegral(dist*densityAdjustment, zStart, zScale*dist*densityAdjustment, fogLower, fogHigher)*fogDensity;
	float distFromCamera = abs(densityIntegral(mvVertexPos.y*densityAdjustment, zStart, zScale*mvVertexPos.y*densityAdjustment, fogLower, fogHigher))*fogDensity;
	float distFromTerrain = distFromCamera - distCameraTerrain;
	if(distCameraTerrain < 10) { // Resolution range is sufficient.
		return distFromTerrain;
	} else {
		if(distFromTerrain > -5) {
			return distFromTerrain;
		} else if(distFromCamera < 5) {
			return distFromCamera - 10;
		} else {
			return -5;
		}
	}
}

void applyFrontfaceFog(float fogDistance, vec3 fogColor) {
	float fogFactor = clamp(exp(fogDistance), 0.0, 1.0);
	fragColor.rgb = fogColor*(1 - fogFactor);
	fragColor.a = fogFactor;
}

void applyBackfaceFog(float fogDistance, vec3 fogColor) {
	float fogFactor = clamp(exp(-abs(fogDistance)), 0.0, 1.0);
	fragColor.rgb = fragColor.rgb*fogFactor + fogColor*(1 - fogFactor);
	fragColor.a *= fogFactor;
}

vec4 fixedCubeMapLookup(vec3 v) { // Taken from http://the-witness.net/news/2012/02/seamless-cube-map-filtering/
	float M = max(max(abs(v.x), abs(v.y)), abs(v.z));
	float scale = (reflectionMapSize - 1)/reflectionMapSize;
	if (abs(v.x) != M) v.x *= scale;
	if (abs(v.y) != M) v.y *= scale;
	if (abs(v.z) != M) v.z *= scale;
	return texture(reflectionMap, v);
}

// Screen-Space Reflections (SSR) for water and transparent surfaces.
//
// Returns the view-space position at UV `screenUv`, reconstructed from the depth buffer — used by the
// binary-search refinement below to test candidate points without re-deriving this each time.
float sampleSceneDepthAt(vec2 screenUv) {
	// This engine's view space uses Y as the forward/depth axis, not -Z (confirmed by this same file's
	// own densityAdjustment a few lines below: sqrt(dot(mvVertexPos,mvVertexPos))/abs(mvVertexPos.y)
	// treats .y as "how far along the view axis") — zFromDepth already returns a Y-axis distance to
	// match.
	return zFromDepth(texture(depthTexture, screenUv).r);
}

uniform float waterReflectionDistance;

vec3 sampleSSR(vec3 viewPos, vec3 reflDir, vec3 fallbackColor) {
	if (!reflectionsEnabled) return fallbackColor;

	vec3 dir = normalize(reflDir);
	float maxDistance = max(32.0, waterReflectionDistance);
	// Was `int(clamp(maxDistance * 1.2, 100.0, 300.0))` — up to 153 steps at the default 128-block
	// waterReflectionDistance, each a full texture sample, plus up to 6 more for the binary-search
	// refinement below on a hit. With a large body of water on screen (many overlapping reflective
	// pixels), this collapsed FPS from ~700 to ~200 — a real, severe cost, not just "SSR is expensive in
	// general." The binary-search refinement already recovers most of the coarse phase's precision
	// cheaply (6 halvings resolve to roughly maxDistance/64 of the original step spacing), so the coarse
	// phase doesn't need anywhere near this many linear steps to reliably find the same crossings — a
	// much smaller, flat cap brings the worst case down by roughly 4-5x while the adaptive depth
	// tolerance below (already scales with distance) keeps larger per-step jumps from missing hits.
	int coarseSteps = 32;
	float coarseStepLength = maxDistance / float(coarseSteps);

	vec3 prevPos = viewPos;

	for (int i = 1; i <= coarseSteps; i++) {
		vec3 currentPos = viewPos + dir * (coarseStepLength * float(i));

		vec4 clipPos = projectionMatrix * vec4(currentPos, 1.0);
		if (clipPos.w <= 0.001) break;
		vec3 ndc = clipPos.xyz / clipPos.w;
		vec2 screenUv = ndc.xy * 0.5 + 0.5;

		if (screenUv.x < 0.01 || screenUv.x > 0.99 || screenUv.y < 0.01 || screenUv.y > 0.99) {
			break;
		}

		float sceneDepth = sampleSceneDepthAt(screenUv);
		float rayDepth = currentPos.y;
		float depthDiff = rayDepth - sceneDepth;

		// Adaptive depth tolerance scales with distance so tall, far mountains and distant scenery are
		// captured reliably without step undershoots. Floor raised from the old fixed 2.0 to
		// coarseStepLength*1.5 — with the coarse step count now much lower (see coarseStepLength's own
		// comment above), individual steps are longer, so the tolerance floor needs to stay comfortably
		// above one step length or a thin/near surface a step could jump clean over would never register
		// a crossing at all.
		float maxTolerance = max(coarseStepLength * 1.5, rayDepth * 0.035);
		if (depthDiff > 0.0 && depthDiff < maxTolerance) {
			vec3 lo = prevPos;
			vec3 hi = currentPos;
			vec2 hitUv = screenUv;
			for (int j = 0; j < 6; j++) {
				vec3 mid = mix(lo, hi, 0.5);
				vec4 midClip = projectionMatrix * vec4(mid, 1.0);
				if (midClip.w <= 0.001) break;
				vec3 midNdc = midClip.xyz / midClip.w;
				vec2 midUv = midNdc.xy * 0.5 + 0.5;
				float midSceneDepth = sampleSceneDepthAt(midUv);
				float midDiff = mid.y - midSceneDepth;
				if (midDiff > 0.0) {
					hi = mid;
					hitUv = midUv;
				} else {
					lo = mid;
				}
			}

			vec3 hitColor = texture(worldColorSampler, hitUv).rgb;
			vec2 edgeFade = smoothstep(vec2(0.0), vec2(0.02), hitUv) * smoothstep(vec2(1.0), vec2(0.98), hitUv);
			float fade = edgeFade.x * edgeFade.y;
			return mix(fallbackColor, hitColor, fade);
		}

		prevPos = currentPos;
	}

	return fallbackColor;
}

void main() {
	if (isBackFace == 0 && !gl_FrontFacing) discard;
	if (isBackFace != 0 && gl_FrontFacing) discard;

	float animatedTextureIndex = animatedTexture[textureIndex];
	bool isWater = textureIndex == waterTextureIndex;
	vec3 textureCoords = vec3(uv, animatedTextureIndex);
	float normalVariation = lightVariation(normal);
	float densityAdjustment = sqrt(dot(mvVertexPos, mvVertexPos))/abs(mvVertexPos.y);
	float dist = zFromDepth(texelFetch(depthTexture, ivec2(gl_FragCoord.xy), 0).r);
	float waterDist = length(mvVertexPos);
	float waterSurfaceDepth = mvVertexPos.y;
	float waterColumnDepth = isWater ? max(0.0, dist - waterSurfaceDepth) : 0.0;
	// The depth-buffer difference alone becomes near-zero when a shallow lake is viewed at a
	// grazing angle, even though the line of sight travels a long way through water. Add a modest
	// view-distance optical path so distant lake/ocean beds fade out rather than becoming clearer.
	float waterOpticalDepth = waterColumnDepth + waterDist * 0.12;
	float depthExtinction = isWater ? exp(-0.16 * waterOpticalDepth) : 1.0;
	float fogDistance = calculateFogDistance(dist, densityAdjustment, playerPositionFraction.z, normalize(direction).z, fogData[int(animatedTextureIndex)].fogDensity, 1e10, 1e10);
	float airFogDistance = calculateFogDistance(dist, densityAdjustment, playerPositionFraction.z, normalize(direction).z, fog.density, fog.fogLower - playerPositionInteger.z, fog.fogHigher - playerPositionInteger.z);
	vec3 fogColor = unpackColor(fogData[int(animatedTextureIndex)].fogColor);
	// Water has its own deliberately stylised surface lighting below. Other transparent solids such
	// as ice must participate in ordinary sun/cloud shadows or they read as self-illuminated.
	float materialShadow = isWater ? 1.0 : combineSunAndCloudShadow(
		sampleSunShadow(direction, normal, length(mvVertexPos), false),
		sampleCloudShadow(direction)
	);
	vec3 pixelLight = max(light*normalVariation*materialShadow, texture(emissionSampler, textureCoords).r*4);
	vec4 textureColor = texture(textureSampler, textureCoords)*vec4(pixelLight, 1);

	// Material reflectivity (from the block's own texture) is read regardless of settings.reflections —
	// that setting only controls whether the expensive SSR raymarch runs, not whether water/glass gets
	// ANY reflection contribution at all. Previously, disabling reflections zeroed rawReflectivity
	// entirely, so water lost its whole specular/sky-tint layer and fell back to just its flat base
	// texture*lighting — reported as "too dark and weird" (water's own base texture is tuned expecting a
	// reflection highlight layered on top, not to look complete on its own). Now a cheap, non-raymarched
	// sky-tint contribution (skyRefl below) still applies with reflections off; only the costly per-pixel
	// SSR search and the full fresnel-boosted specular sheen are skipped.
	float materialReflectivity = texture(reflectivityAndAbsorptionSampler, textureCoords).a;
	// Above a water surface, distant shallow bottoms need to disappear even when the depth buffer
	// cannot provide a reliable water-column thickness at a grazing angle. Deliberately restrict this
	// artistic surface opacity to upward-facing water viewed from above; underwater/side rendering is
	// unchanged.
	float playerWorldZ = float(playerPositionInteger.z) + playerPositionFraction.z;
	bool aboveWaterSurface = isWater && normal.z > 0.9 && playerWorldZ > worldPos.z + 0.05;
	bool belowWaterSurface = isWater && normal.z > 0.9 && playerWorldZ < worldPos.z - 0.05;
	float surfaceDistanceFade = aboveWaterSurface ? 1.0 - exp(-waterDist * 0.035) : 0.0;
	// Rain/snow turns the otherwise sharp sky/SSR reflection into diffuse overcast light. This also
	// removes the conspicuous bright reflective disc directly around the player while weather haze is on.
	float weatherWaterReflectionFade = aboveWaterSurface ? smoothstep(0.02, 0.25, weatherFogStrength) : 0.0;
	// In weather, transparent water must disappear into the same atmosphere before the already-fogged
	// lakebed behind it. Otherwise the bed remains visible while the far surface effectively vanishes.
	// This is only for water viewed from above: ice/glass and all underwater views retain their normal path.
	float weatherWaterHaze = aboveWaterSurface ? weatherFogStrength*smoothstep(18.0, 120.0, waterDist) : 0.0;

	// Water ripple animation:
	// Distance-fade out the ripples so close-up water has gentle motion, while distant water stays flat.
	// This prevents distant ripples from tilting into the dark ground tint (which produced jarring black pixels far away).
	float rippleRangeFade = smoothstep(40.0, 10.0, waterDist);

	// World-space organic ocean wave harmonics (no dot patterns, anchored to world coordinates):
	vec2 wUv = worldPos.xy * 0.4;
	float wave1 = sin(wUv.x * 0.9 + wUv.y * 0.6 + waterTime * 1.6);
	float wave2 = cos(wUv.x * 0.5 - wUv.y * 1.2 + waterTime * 1.3);
	float wave3 = sin(wUv.x * 1.4 + wUv.y * 1.8 - waterTime * 2.1);

	float rippleX = isWater ? (wave1 * 0.005 + wave2 * 0.003 - wave3 * 0.002) * rippleRangeFade : 0.0;
	float rippleY = isWater ? (wave1 * 0.003 - wave2 * 0.005 + wave3 * 0.003) * rippleRangeFade : 0.0;

	vec3 rippledNormal = normalize(normal + vec3(rippleX, rippleY, 0.0));
	vec3 reflDir = reflect(normalize(direction), rippledNormal);

	vec3 groundReflTint = fog.color * 0.45;
	vec3 skyRefl = mix(groundReflTint, fog.color, smoothstep(-0.1, 0.25, reflDir.z));
	vec3 viewSpaceReflDir = (viewMatrix * vec4(reflDir, 0.0)).xyz;
	// waterReflectionDistance previously only controlled how far each SSR ray was allowed to SEARCH
	// (sampleSSR's maxDistance) — the ray still searches along its own reflected direction, which can
	// point toward distant scenery (e.g. a tall mountain) regardless of how close the reflecting water
	// itself is to the player. That meant a low slider value didn't limit "how far away reflections
	// render" the way the setting is meant to (a mountain at the search-distance edge would still show
	// fully) — it only affected reflection reach/detail, not visibility radius. Gate the raymarch itself
	// on this water FRAGMENT's own distance from the player (waterDist, already computed above for the
	// ripple fade) instead: water beyond waterReflectionDistance skips SSR entirely and falls back to the
	// flat sky/ground tint, same as the reflectionsEnabled-off path — regardless of what a ray from there
	// could technically reach.
	bool withinReflectionDistance = isWater && waterDist <= waterReflectionDistance;
	vec3 reflColor = (reflectionsEnabled && withinReflectionDistance) ? sampleSSR(mvVertexPos, viewSpaceReflDir, skyRefl) : skyRefl;

	// Add realistic sun specular glint on water surface ripples:
	vec3 sunDir = normalize((viewMatrix * vec4(sunDirection, 0.0)).xyz);
	float sunSpecular = isWater ? pow(max(0.0, dot(normalize(viewSpaceReflDir), sunDir)), 48.0) * 1.2 : 0.0;
	reflColor += vec3(1.0, 0.95, 0.85) * sunSpecular * (reflectionsEnabled ? 1.0 : 0.4) * (1.0 - weatherWaterReflectionFade);

	float fresnel = clamp(pow(1.0 + dot(normalize(direction), normal), 2.0), 0.0, 1.0);
	float fresnelBoost = reflectionsEnabled ? (0.05 + 0.45 * fresnel) : 0.05;
	float specularReflectivity = materialReflectivity * fresnelBoost;

	textureColor.rgb *= textureColor.a;
	if (isWater && materialReflectivity > 0.01) {
		textureColor.rgb += reflColor * specularReflectivity * mix(0.70, 0.12, weatherWaterReflectionFade);
	}
	blendColor.rgb = vec3(1.0 - textureColor.a);
	if (aboveWaterSurface) {
		// As the surface recedes, transition toward deep water and strongly attenuate the
		// scene already behind it. This is separate from underwater fog/caustics.
		vec3 deepWater = vec3(0.015, 0.075, 0.11) * max(pixelLight, vec3(0.25)) * textureColor.a;
		textureColor.rgb = mix(textureColor.rgb, deepWater, surfaceDistanceFade * 0.75);
		blendColor.rgb *= 1.0 - surfaceDistanceFade * 0.90;
		// Close the transparent blend progressively into a deep, rain-tinted water volume. The source
		// colour still receives normal air fog below, so this transitions smoothly rather than forming a
		// dark opaque water wall at the weather range.
		blendColor.rgb *= 1.0 - weatherWaterHaze * 0.98;
	}
	// Atmospheric sky fog is appropriate for ice/glass and for the world beyond water, but applying
	// its bright sky colour *inside the water blend* makes a distant lake bed lighter and clearer.
	// Above a water surface, replace that contribution with a deep-water extinction colour instead.
	vec3 transparentFogColor = aboveWaterSurface ? vec3(0.012, 0.055, 0.085) : fog.color;
	if (weatherWaterHaze > 0.0) {
		// Fog this surface by its own distance, not the opaque terrain depth sampled behind it. The latter
		// is precisely what made a far shallow lake look as though its water had been removed in rain.
		airFogDistance = -waterDist*fog.density*mix(5.0, 11.0, weatherFogStrength);
	}

	// Render the water ceiling through one dedicated path before the regular front/back-face split.
	// Depending on the face's generated winding, the top surface can arrive through either path;
	// tying the effect to `isBackFace` therefore left it invisible in practice. This is intentionally
	// unlit enough to remain legible at night, and more opaque than ordinary water so it gives a
	// reliable visual route toward air.
	if (belowWaterSurface) {
		float surfaceDepth = worldPos.z - playerWorldZ;
		float surfaceProximity = exp(-surfaceDepth * 0.08);
		vec3 undersideTextureCoords = vec3(vec2(1.0 - uv.x, uv.y), animatedTextureIndex);
		vec3 undersidePattern = texture(textureSampler, undersideTextureCoords).rgb * (0.32 + 0.42 * surfaceProximity);
		vec3 surfaceGlow = vec3(0.055, 0.24, 0.42) * (0.50 + 0.50 * surfaceProximity);
		fragColor.rgb = undersidePattern + surfaceGlow;
		blendColor.rgb = mix(vec3(0.34, 0.48, 0.62), vec3(0.12, 0.22, 0.34), surfaceProximity);
		fragColor.a = 1.0;
		return;
	}

	if(isBackFace == 0) {
		vec3 absorption = texture(reflectivityAndAbsorptionSampler, textureCoords).rgb;
		blendColor.rgb *= absorption * vec3(depthExtinction);

		// Fake reflection:
		// TODO: Change this when it rains.
		// TODO: Normal mapping.
		textureColor.rgb += texture(emissionSampler, textureCoords).rgb;

		// Apply the air fog so frontface water surfaces blend naturally with atmospheric sky fog:
		applyFrontfaceFog(airFogDistance, transparentFogColor);

		// Apply the texture+absorption
		fragColor.rgb *= blendColor.rgb;
		fragColor.rgb += textureColor.rgb;

		// Apply the air fog:
		applyBackfaceFog(airFogDistance, transparentFogColor);
	} else if (isWater) {
		// Water surface underside (backface) viewed from underwater:
		// Caustic ripple pattern that modulates the sky/outside background color with dark wave lines and bright shimmering highlights.
		vec2 rippleUv = direction.xy * 0.35 + vec2(waterTime * 0.3);
		float wave1 = sin(rippleUv.x * 3.2 + rippleUv.y * 2.1 + waterTime * 1.8) * 0.5 + 0.5;
		float wave2 = cos(rippleUv.x * 4.8 - rippleUv.y * 3.4 - waterTime * 1.4) * 0.5 + 0.5;
		float backfaceWave = wave1 * wave2;

		// Modulate background: dark wave shadow lines (0.60) and bright shimmering caustic crests (1.30)
		vec3 waveModulation = mix(vec3(0.55, 0.70, 0.90), vec3(1.15, 1.30, 1.45), backfaceWave);

		fragColor.rgb = textureColor.rgb * 0.20;
		blendColor.rgb = waveModulation;
		fragColor.a = 1.0;
		return;
	} else {
		// Generic transparent materials (ice, glass, etc.) retain their own texture and
		// alpha blend, but never inherit water's underwater caustics or animated surface.
		fragColor.rgb = textureColor.rgb;
		blendColor.rgb = vec3(1.0 - textureColor.a);
		fragColor.a = 1.0;
		return;
	}
	blendColor.rgb *= fragColor.a;
	fragColor.a = 1;
}
