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
	float fogFactor = exp(fogDistance);
	fragColor.rgb = fogColor*(1 - fogFactor);
	fragColor.a = fogFactor;
}

void applyBackfaceFog(float fogDistance, vec3 fogColor) {
	float fogFactor = exp(-fogDistance);
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

vec3 sampleSSR(vec3 viewPos, vec3 reflDir, vec3 fallbackColor) {
	if (!reflectionsEnabled) return fallbackColor;

	vec3 dir = normalize(reflDir);
	// Phase 1 — coarse march: fixed step length (not geometrically growing) so a hit's *approximate*
	// location is found with roughly even precision at any distance along the ray, rather than the
	// previous version's step size compounding ~9.6x over its 20 iterations — most of that march's
	// reach was very low-precision, coarse jumps, which is what produced a warped-looking reflection
	// that only "locked on" cleanly from angles where an early, still-precise step happened to land
	// near the real surface (matching the player's own report: "only from a very specific angle...
	// messed up"). A plain, larger step count at constant length instead gives consistent precision
	// across the whole search range; the phase-2 refinement below is what actually sharpens the hit,
	// not a growing step size.
	// Player-reported "reflection distance is very close" after the coordinate-space fix confirmed the
	// march itself now works correctly — 0.5*48=24 blocks total reach was simply too short to catch
	// typical scenery (distant trees, far shoreline). Raised reach to 100 blocks (0.5*200) while keeping
	// the same per-step length/precision — a longer search costs more worst-case texture samples per
	// reflective pixel (only paid when a ray doesn't hit early), not a change to precision.
	const float coarseStepLength = 0.5;
	const int coarseSteps = 200;

	vec3 prevPos = viewPos;

	for (int i = 1; i <= coarseSteps; i++) {
		vec3 currentPos = viewPos + dir * (coarseStepLength * float(i));

		vec4 clipPos = projectionMatrix * vec4(currentPos, 1.0);
		if (clipPos.w <= 0.001) break; // Ray went behind the camera — nothing further to test.
		vec3 ndc = clipPos.xyz / clipPos.w;
		vec2 screenUv = ndc.xy * 0.5 + 0.5;

		if (screenUv.x < 0.01 || screenUv.x > 0.99 || screenUv.y < 0.01 || screenUv.y > 0.99) {
			break; // Left the screen — nothing further along this ray is visible to reflect.
		}

		float sceneDepth = sampleSceneDepthAt(screenUv);
		float rayDepth = currentPos.y;
		float depthDiff = rayDepth - sceneDepth;

		// The ray has crossed from "in front of" (diff < 0) to "behind" (diff > 0) the visible surface
		// — i.e. it just passed through the surface it should reflect off. Only trust a crossing within
		// a small absolute tolerance (not the old, ever-loosening one) so distant, unrelated geometry the
		// ray happens to pass near isn't mistaken for the intended reflection surface.
		if (depthDiff > 0.0 && depthDiff < 2.0) {
			// Phase 2 — binary search refinement between prevPos (known in-front) and currentPos (known
			// behind) to pin down the actual crossing point precisely, instead of accepting this coarse
			// step's position as the hit directly. Standard SSR refinement technique.
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
			// Fades reflections out near the screen edge because a ray that exits the visible frame has no
			// further information to sample — not because content right at the edge is somehow unreliable.
			// The old 8%-of-screen fade band was too wide: it visibly blurred away reflections of things
			// still clearly on-screen near the edge (player-reported: "i can still see the leaf on the edge
			// of screen but on the water reflection there is like a soft blur removing it"). Narrowed to a
			// 2% band — just enough to avoid a hard, single-pixel cutoff right at the true screen boundary,
			// without discarding reflections of content that's still comfortably visible.
			vec2 edgeFade = smoothstep(vec2(0.0), vec2(0.02), hitUv) * smoothstep(vec2(1.0), vec2(0.98), hitUv);
			float fade = edgeFade.x * edgeFade.y;
			return mix(fallbackColor, hitColor, fade);
		}

		prevPos = currentPos;
	}

	return fallbackColor;
}

void main() {
	float animatedTextureIndex = animatedTexture[textureIndex];
	vec3 textureCoords = vec3(uv, animatedTextureIndex);
	float normalVariation = lightVariation(normal);
	float densityAdjustment = sqrt(dot(mvVertexPos, mvVertexPos))/abs(mvVertexPos.y);
	float dist = zFromDepth(texelFetch(depthTexture, ivec2(gl_FragCoord.xy), 0).r);
	float fogDistance = calculateFogDistance(dist, densityAdjustment, playerPositionFraction.z, normalize(direction).z, fogData[int(animatedTextureIndex)].fogDensity, 1e10, 1e10);
	float airFogDistance = calculateFogDistance(dist, densityAdjustment, playerPositionFraction.z, normalize(direction).z, fog.density, fog.fogLower - playerPositionInteger.z, fog.fogHigher - playerPositionInteger.z);
	vec3 fogColor = unpackColor(fogData[int(animatedTextureIndex)].fogColor);
	vec3 pixelLight = max(light*normalVariation, texture(emissionSampler, textureCoords).r*4);
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
	// Subtle ripple: perturbs only the normal used for the REFLECTION direction (not lighting/fresnel's
	// own `normal`, which should stay based on the true flat surface) so the reflection wobbles gently
	// instead of being a perfectly flat mirror. A flat mirror reflection of a tall object (e.g. a palm
	// tree) is inherently ambiguous with "looking through the water surface at the tree's trunk
	// underwater" from directly above/up close — real water avoids this ambiguity with constant small
	// surface motion, which a perfectly static SSR reflection has none of. Cheap two-octave sine wave in
	// world XY (direction.xy — camera-relative, fine for a purely visual ripple pattern that doesn't need
	// to be pixel-stable across frames) animated by waterTime; small enough amplitude to read as gentle
	// water motion, not distort the reflection's overall shape/position.
	vec2 ripplePos = direction.xy * 0.3;
	float rippleX = sin(ripplePos.x*1.3 + ripplePos.y*0.7 + waterTime*1.1)*0.02
		+ sin(ripplePos.x*2.9 - ripplePos.y*1.7 + waterTime*1.9)*0.01;
	float rippleY = sin(ripplePos.y*1.3 - ripplePos.x*0.7 + waterTime*1.3)*0.02
		+ sin(ripplePos.y*2.9 + ripplePos.x*1.7 + waterTime*2.1)*0.01;
	vec3 rippledNormal = normalize(normal + vec3(rippleX, rippleY, 0.0));
	vec3 reflDir = reflect(normalize(direction), rippledNormal);
	// fixedCubeMapLookup (below) samples a static, meaningless procedural noise pattern generated once
	// at startup (fake_reflection.frag) with no relation to the actual sky/world — whenever SSR (which
	// only sees on-screen geometry) doesn't find a real hit, every reflective surface fell back to this
	// noise, which is what read as "water just glowing, nothing reflected." Real sky color (fog.color,
	// already time-of-day/weather-correct) is a far more sensible fallback for the common "reflection
	// points at open sky" case — reflDir.z (world-space up, since direction/normal here are both
	// world-space per chunk_vertex.vert) picks between sky color for upward-pointing reflections and a
	// darker, desaturated tone for downward ones (reflecting into the ground/water itself, which
	// shouldn't show sky color at all).
	vec3 groundReflTint = fog.color * 0.35;
	vec3 skyRefl = mix(groundReflTint, fog.color, smoothstep(-0.2, 0.3, reflDir.z));
	// sampleSSR marches from mvVertexPos (VIEW-space) and needs a VIEW-space step direction — reflDir
	// above is WORLD-space (direction/normal are both world-space per chunk_vertex.vert). Passing the
	// world-space reflDir straight into a view-space march was a real, previously-undiagnosed bug: adding
	// a world-space vector directly to a view-space position is meaningless, and the resulting (wrong)
	// path changes with camera ROTATION specifically — exactly matching the player's report that the
	// reflection "moves in a random position" when looking up/around, not with camera movement or
	// distance (which the earlier step-size rework, itself a real but insufficient fix, couldn't touch).
	// viewMatrix is a pure rotation (no translation — see game.zig's camera.viewMatrix, rotationX*rotationZ
	// with no translate), so transforming a direction is just viewMatrix * vec4(dir, 0).
	vec3 viewSpaceReflDir = (viewMatrix * vec4(reflDir, 0.0)).xyz;
	vec3 reflColor = reflectionsEnabled ? sampleSSR(mvVertexPos, viewSpaceReflDir, skyRefl) : skyRefl;

	float fresnel = clamp(pow(1.0 + dot(normalize(direction), normal), 2.0), 0.0, 1.0);
	// fresnelBoost's floor (the additive term with no fresnel dependence) was 0.5 — even looking
	// straight down at water (near-zero fresnel, where a reflection should be at its WEAKEST) the
	// reflection was never less than half strength. Combined with the *1.20 overall multiplier below,
	// worst case was materialReflectivity * 1.0 * 1.20 — close to fully replacing the water's own base
	// color with the (now correctly bright, sky-colored) reflection, reported as still-too-much glow even
	// after removing the pixelLight double-multiplication. Lowered the floor to 0.15 so reflection
	// strength actually tracks viewing angle the way real water does (near-invisible looking straight
	// down, strong at grazing angles) instead of always showing at least half strength regardless of
	// angle.
	float fresnelBoost = reflectionsEnabled ? (0.15 + 0.55 * fresnel) : 0.15;
	float specularReflectivity = materialReflectivity * fresnelBoost;

	textureColor.rgb *= textureColor.a;
	if (materialReflectivity > 0.01) {
		// Was `reflColor * pixelLight * specularReflectivity * 1.20` — multiplying the reflection by the
		// water TILE's own local lighting term (pixelLight) as well as its own brightness compounds two
		// already-bright values under direct midday sun (pixelLight near its max, and skyRefl/reflColor
		// also near its brightest), which is what read as "water glows too much during sun" while looking
		// fine at night (both terms are naturally dim then, so the same formula stayed reasonable). A
		// mirror reflecting the sky shows the sky's own brightness — it shouldn't ALSO be re-multiplied by
		// how brightly lit the water surface itself happens to be; that's already accounted for by
		// specularReflectivity/fresnel controlling how much of the reflection shows through at all.
		textureColor.rgb += reflColor * specularReflectivity * 1.20;
	}
	blendColor.rgb = vec3(1.0 - textureColor.a);

	if(isBackFace == 0) {
		vec3 absorption = texture(reflectivityAndAbsorptionSampler, textureCoords).rgb;
		blendColor.rgb *= absorption;

		// Fake reflection:
		// TODO: Change this when it rains.
		// TODO: Normal mapping.
		textureColor.rgb += texture(emissionSampler, textureCoords).rgb;

		if(fogData[int(animatedTextureIndex)].fogDensity == 0.0) {
			// Apply the air fog, compensating for the potentially missing back-face:
			applyFrontfaceFog(airFogDistance, fog.color);
		} else {
			// Apply the block fog:
			applyFrontfaceFog(fogDistance, fogColor);
		}

		// Apply the texture+absorption
		fragColor.rgb *= blendColor.rgb;
		fragColor.rgb += textureColor.rgb;

		// Apply the air fog:
		applyBackfaceFog(airFogDistance, fog.color);
	} else {
		// Apply the air fog:
		applyFrontfaceFog(airFogDistance, fog.color);

		// Apply the texture:
		fragColor.rgb *= blendColor.rgb;
		fragColor.rgb += textureColor.rgb;

		// Apply the block fog:
		if(fogData[int(animatedTextureIndex)].fogDensity == 0.0) {
			// Apply the air fog, compensating for the above line where I compensated for the potentially missing back-face.
			applyBackfaceFog(airFogDistance, fog.color);
		} else {
			applyBackfaceFog(fogDistance, fogColor);
		}
	}
	blendColor.rgb *= fragColor.a;
	fragColor.a = 1;
}
