#version 460

#include "frame_uniforms.glsl"

layout(location = 0) in vec3 mvVertexPos;
layout(location = 1) in vec3 direction;
layout(location = 2) in vec3 outSunLight;
layout(location = 3) in vec2 uv;
layout(location = 4) flat in vec3 normal;
layout(location = 5) flat in int textureIndex;
layout(location = 6) flat in int isBackFace;
layout(location = 7) flat in float distanceForLodCheck;
layout(location = 8) flat in int opaqueInLod;
layout(location = 9) in vec3 outBlockLight;
layout(location = 10) flat in int isFoliage;

layout(location = 0) out vec4 fragColor;

layout(binding = 0) uniform sampler2DArray textureSampler;
layout(binding = 1) uniform sampler2DArray emissionSampler;
layout(binding = 2) uniform sampler2DArray reflectivityAndAbsorptionSampler;
layout(binding = 4) uniform samplerCube reflectionMap;
layout(binding = 5) uniform sampler2D ditherTexture;

layout(location = 5) uniform float reflectionMapSize;
layout(location = 6) uniform float contrast;
layout(location = 7) uniform float lodDistance;

uniform vec3 handLightPositionRelative;
uniform vec3 handLightColor;
uniform vec3 dropLightPositionRelative;
uniform vec3 dropLightColor;
uniform float handLightRadius;
uniform bool reflectionsEnabled;
// Supplied by the block registry. Snow uses a material-local shadow softening so its high albedo
// does not create disproportionately harsh dark patches.
uniform int snowTextureIndex;

layout(std430, binding = 1) buffer _animatedTexture
{
	float animatedTexture[];
};

#include "shadow.glsl"

uniform float weatherShadowFade;

float lightVariation(vec3 normal) {
	const vec3 directionalPart = vec3(0, contrast/2, contrast);
	const float baseLighting = 1 - contrast;
	return baseLighting + dot(normal, directionalPart);
}

bool passDitherTest(float alpha) {
	if(opaqueInLod != 0) {
		if(distanceForLodCheck > lodDistance) return true;
		float factor = max(0, distanceForLodCheck - (lodDistance - 32.0))/32.0;
		alpha = alpha*(1 - factor) + factor;
	}
	return alpha > texture(ditherTexture, uv).r*255.0/256.0 + 0.5/256.0;
}

vec3 handLightContribution() {
	if (handLightRadius == 0.0) return vec3(0.0);

	vec3 totalLight = vec3(0.0);
	if (handLightColor != vec3(0.0)) {
		float dist = length(direction - handLightPositionRelative);
		float normDist = clamp(dist / handLightRadius, 0.0, 1.0);
		float atten = (1.0 - normDist) * (1.0 - normDist);
		float peakHighlight = 1.0 + 0.5 * (1.0 - normDist) * (1.0 - normDist);
		totalLight += handLightColor * atten * peakHighlight;
	}
	if (dropLightColor != vec3(0.0)) {
		float dist = length(direction - dropLightPositionRelative);
		float normDist = clamp(dist / handLightRadius, 0.0, 1.0);
		float atten = (1.0 - normDist) * (1.0 - normDist);
		float peakHighlight = 1.0 + 0.5 * (1.0 - normDist) * (1.0 - normDist);
		totalLight += dropLightColor * atten * peakHighlight;
	}
	return totalLight;
}

vec4 fixedCubeMapLookup(vec3 v) { // Taken from http://the-witness.net/news/2012/02/seamless-cube-map-filtering/
	float M = max(max(abs(v.x), abs(v.y)), abs(v.z));
	float scale = (reflectionMapSize - 1)/reflectionMapSize;
	if (abs(v.x) != M) v.x *= scale;
	if (abs(v.y) != M) v.y *= scale;
	if (abs(v.z) != M) v.z *= scale;
	return texture(reflectionMap, v);
}

void main() {
	float animatedTextureIndex = animatedTexture[textureIndex];
	// Cube leaf blocks are a dense, cutout canopy rather than a hard material with six visibly separate
	// lit faces. Applying full block-face directional contrast creates the dark vertical seam around every
	// leaf cube. Retain a little shape cue, but keep foliage lighting cohesive across the canopy.
	float normalVariation = (opaqueInLod == 0) ? 1.0 : lightVariation(normal);
	if (isFoliage != 0) {
		normalVariation = mix(1.0, normalVariation, 0.22);
	}
	vec2 clampedUv = uv;
	if (isFoliage != 0) {
		vec2 tile = clamp(floor((uv - vec2(0.0005)) * 4.0), vec2(0.0), vec2(3.0));
		vec2 minUv = tile * 0.25 + vec2(0.0005);
		vec2 maxUv = (tile + vec2(1.0)) * 0.25 - vec2(0.0005);
		clampedUv = clamp(uv, minUv, maxUv);
	}
	vec3 textureCoords = vec3(clampedUv, animatedTextureIndex);
	float texAlpha = texture(textureSampler, textureCoords).a;

	// For foliage/cutout geometry under MSAA: use fwidth-based alpha rescaling (Ben Golus technique)
	// so GL_SAMPLE_ALPHA_TO_COVERAGE generates smooth sub-pixel coverage masks at texture edges,
	// eliminating the visible wireframe "string" along polygon borders of cross.obj quads.
	// fwidth(texAlpha) measures how fast alpha changes across this pixel; dividing by it normalizes
	// the alpha transition to exactly 1 pixel width, giving A2C hardware a clean gradient to work with.
	if (isFoliage != 0 || opaqueInLod == 0) {
		float cutoff = 0.5;
		float alphaDerivative = fwidth(texAlpha);
		texAlpha = (texAlpha - cutoff) / max(alphaDerivative, 0.0001) + 0.5;
		texAlpha = clamp(texAlpha, 0.0, 1.0);
		if (texAlpha < 0.001) discard;
	}

	float rawReflectivity = reflectionsEnabled ? texture(reflectivityAndAbsorptionSampler, textureCoords).a : 0.0;
	vec3 reflectionColor = vec3(0.0);
	float specularSheen = 0.0;
	if (rawReflectivity > 0.01) {
		// A neutral sky/cubemap reflection on a saturated gem reads as flat chalk-white rather than as a
		// polished material. Colour the broad reflected lobe from the material's albedo: ruby remains
		// deep red, diamond/jade retain their cool hue, gold stays warm, while iron/silver naturally stay
		// close to neutral because their base textures are nearly grey. Gamma lifting avoids crushing
		// highlights in dark texture details.
		vec3 materialTint = pow(texture(textureSampler, textureCoords).rgb, vec3(0.55));
		vec3 reflDir = reflect(normalize(direction), normal);
		reflectionColor = fixedCubeMapLookup(reflDir).rgb * mix(vec3(1.0), materialTint, 0.82);
		float fresnel = clamp(pow(1.0 + dot(normalize(direction), normal), 2.0), 0.0, 1.0);
		// The texture maps already encode material class and roughness: coal/sulfur are zero, ore host
		// stone stays black, raw veins are sparse/low, and crafted metals/cut gems are substantially
		// brighter. Give those authored values enough response to be visibly distinguishable in play.
		specularSheen = rawReflectivity * (0.28 + 0.72 * fresnel);
	}

	// isFoliage (the vertex-attribute int) is a real per-model flag set by models.zig from each model's
	// .zig.zon (`isFoliage = true`), NOT derived from opaqueInLod. opaqueInLod==0 also covers any
	// non-face-aligned procedural geometry (branches, ore veins), which used to wrongly get grass's
	// SSS/root-AO/shadow self-occlusion handling below just because it isn't flat on a block boundary.
	bool shadedAsFoliage = isFoliage != 0;
	float directionalShadow = sampleSunShadow(direction, normal, length(mvVertexPos), shadedAsFoliage);
	float shadowFactor = combineSunAndCloudShadow(directionalShadow, sampleCloudShadow(direction));
	// Dense alpha-cutout cube leaves otherwise shadow their neighbouring leaf cubes very aggressively,
	// producing dark canopy patches. Keep this leaf-only softening off grass/plant quads so they retain
	// their normal, visible shadow response.
	if (shadedAsFoliage && opaqueInLod != 0) {
		shadowFactor = mix(shadowFactor, 1.0, 0.65);
	}
	// Bright snow makes the standard terrain shadow floor appear much darker than its surroundings.
	// Keep contact/form detail, but diffuse 60% of that contrast for snow alone.
	if (textureIndex == snowTextureIndex) {
		shadowFactor = mix(shadowFactor, 1.0, 0.60);
	}
	// Rain/snow clouds turn the directional sun into diffuse overcast light. Preserve a small amount of
	// form shading but remove the hard, sunny shadow contrast while local weather is active.
	shadowFactor = mix(shadowFactor, 1.0, weatherShadowFade);

	vec3 effectiveSunLight = outSunLight;
	// Subsurface Scattering (SSS) / Translucency for foliage (grass blades, flowers, crops):
	// Direct sunlight penetrating thin plant tissue causes the back face of grass to glow brightly.
	// Applied to outSunLight only (not outBlockLight) — this is specifically light passing through leaf
	// tissue from the sun/moon side, a torch's blockLight doesn't participate.
	if (shadedAsFoliage) {
		vec3 lightDir = normalize(sunDirection);
		float NdotL = dot(normal, lightDir);

		// Grass/plant cross-quads are vertical planes with *horizontal* normals (cross.obj: normals are
		// (+-0.707, +-0.707, 0), Z being up), so with the sun anywhere near overhead NdotL is ~0 for every
		// blade regardless of which way it faces. The previous `clamp(0.5 - 0.5*NdotL, 0.0, 0.25)` therefore
		// sat pinned at its 0.25 maximum from morning to evening: not a translucency term at all in
		// practice, just a flat +25% brightener that made foliage read as permanently lighter than the very
		// ground it grows out of (it only fell below max once NdotL > 0.5, i.e. the sun within 60 degrees of
		// a blade's horizontal normal — sunrise/sunset only).
		//
		// Light actually passing *through* a blade requires the sun behind it and low enough to shine
		// sideways through the plane, so gate the effect on both of those. With the sun overhead this is 0
		// and foliage matches the surrounding ground exactly; at sunrise/sunset back-lit blades pick up a
		// gentle rim glow, which is when real grass visibly glows.
		float backLight = clamp(-NdotL, 0.0, 1.0);
		float sunLowness = 1.0 - clamp(abs(lightDir.z), 0.0, 1.0);
		float sssTranslucency = backLight * sunLowness * 0.18;
		float sssIntensity = isSunlight ? 1.0 : 0.1;

		// uv.y runs 0 at the blade root to 1 at the tip (cross.obj maps z=0 -> v=0, z=1 -> v=1). The old
		// `min(uv.y, 1.0 - uv.y)` was symmetric, so it darkened the tip just as much as the root, and at LOD
		// distance (chunk_vertex.vert scales uv by voxelSize, pushing uv.y above 1) `1.0 - uv.y` went
		// negative and flat-darkened *all* distant foliage by the full 30%. Only the root — genuinely
		// occluded by surrounding blades and the ground — should darken.
		// `cube_leaf.obj` uses compact atlas UVs (different faces occupy different 0.25-wide
		// regions), so applying a grass-root gradient to it permanently darkens parts of a
		// leaf cube based on texture coordinates. Only non-face-aligned foliage is a rooted
		// plant blade/quad; cube leaves must keep uniform diffuse lighting.
		float rootAO = opaqueInLod == 0 ? mix(0.70, 1.0, smoothstep(0.0, 0.4, uv.y)) : 1.0;

		effectiveSunLight = outSunLight * (1.0 + sssTranslucency * sssIntensity) * rootAO;
	}

	vec3 handLight = handLightContribution();
	float handIntensity = max(handLight.r, max(handLight.g, handLight.b));
	float effectiveShadow = mix(shadowFactor, 1.0, clamp(handIntensity * 3.0, 0.0, 1.0));

	vec3 directSunAndShadow = effectiveSunLight * effectiveShadow;
	vec3 totalLight = min(directSunAndShadow + handLight + outBlockLight, vec3(1.0));
	vec3 pixelLight = max(totalLight*normalVariation, texture(emissionSampler, textureCoords).r*4);
	fragColor = texture(textureSampler, textureCoords)*vec4(pixelLight, 1);
	if (rawReflectivity > 0.01) {
		// This is deliberately stronger than the old almost imperceptible 0.40 multiplier. It leaves
		// truly matte maps at exactly zero, keeps raw ore as small glints, and makes polished metal/gem
		// blocks and bars visibly read as a different material under normal daylight.
		fragColor.rgb += reflectionColor * pixelLight * specularSheen * 0.95;
	}

	if(!passDitherTest(fragColor.a)) discard;
	if (isFoliage != 0 || opaqueInLod == 0) {
		fragColor.a = texAlpha;
	} else {
		fragColor.a = 1;
	}
}
