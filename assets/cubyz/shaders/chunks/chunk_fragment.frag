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
layout(location = 11) in vec3 worldPos;

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
uniform vec3 dropLightPosition0;
uniform vec3 dropLightColor0;
uniform vec3 dropLightPosition1;
uniform vec3 dropLightColor1;
uniform vec3 dropLightPosition2;
uniform vec3 dropLightColor2;
uniform vec3 dropLightPosition3;
uniform vec3 dropLightColor3;
uniform vec3 dropLightPosition4;
uniform vec3 dropLightColor4;
uniform vec3 dropLightPosition5;
uniform vec3 dropLightColor5;
uniform vec3 dropLightPosition6;
uniform vec3 dropLightColor6;
uniform vec3 dropLightPosition7;
uniform vec3 dropLightColor7;
uniform float handLightRadius;
uniform vec3 remoteHandLightPositionRelative;
uniform vec3 remoteHandLightColor;
uniform bool reflectionsEnabled;

uniform int snowTextureIndex;

// Only used by PlanarReflection's offscreen pass (src/renderer.zig) to cull geometry on the far
// side of the mirror plane - the normal opaque pass leaves clipPlaneEnabled false.
uniform bool clipPlaneEnabled;
uniform float clipPlaneZ;

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
	vec3 dropPositions[8] = vec3[8](dropLightPosition0, dropLightPosition1, dropLightPosition2, dropLightPosition3, dropLightPosition4, dropLightPosition5, dropLightPosition6, dropLightPosition7);
	vec3 dropColors[8] = vec3[8](dropLightColor0, dropLightColor1, dropLightColor2, dropLightColor3, dropLightColor4, dropLightColor5, dropLightColor6, dropLightColor7);
	for (int i = 0; i < 8; ++i) {
		if (dropColors[i] == vec3(0.0)) continue;
		float dist = length(direction - dropPositions[i]);
		float normDist = clamp(dist / handLightRadius, 0.0, 1.0);
		float atten = (1.0 - normDist) * (1.0 - normDist);
		float peakHighlight = 1.0 + 0.5 * (1.0 - normDist) * (1.0 - normDist);
		totalLight += dropColors[i] * atten * peakHighlight;
	}
	if (remoteHandLightColor != vec3(0.0)) {
		float dist = length(direction - remoteHandLightPositionRelative);
		float normDist = clamp(dist / handLightRadius, 0.0, 1.0);
		float atten = (1.0 - normDist) * (1.0 - normDist);
		float peakHighlight = 1.0 + 0.5 * (1.0 - normDist) * (1.0 - normDist);
		totalLight += remoteHandLightColor * atten * peakHighlight;
	}
	return totalLight;
}

vec4 fixedCubeMapLookup(vec3 v) {
	float M = max(max(abs(v.x), abs(v.y)), abs(v.z));
	float scale = (reflectionMapSize - 1)/reflectionMapSize;
	if (abs(v.x) != M) v.x *= scale;
	if (abs(v.y) != M) v.y *= scale;
	if (abs(v.z) != M) v.z *= scale;
	return texture(reflectionMap, v);
}

void main() {
	if (clipPlaneEnabled && worldPos.z < clipPlaneZ) discard;

	float animatedTextureIndex = animatedTexture[textureIndex];

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

	if (isFoliage != 0) {
		float cutoff = 0.5;
		float alphaDerivative = fwidth(texAlpha);
		texAlpha = (texAlpha - cutoff) / max(alphaDerivative, 0.0001) + 0.5;
		texAlpha = clamp(texAlpha, 0.0, 1.0);
		if (texAlpha < 0.001) discard;
	} else if (opaqueInLod == 0) {

		if (texAlpha < 0.001) discard;
	}

	float rawReflectivity = reflectionsEnabled ? texture(reflectivityAndAbsorptionSampler, textureCoords).a : 0.0;
	vec3 reflectionColor = vec3(0.0);
	float specularSheen = 0.0;
	if (rawReflectivity > 0.01) {

		vec3 materialTint = pow(texture(textureSampler, textureCoords).rgb, vec3(0.55));
		vec3 reflDir = reflect(normalize(direction), normal);
		reflectionColor = fixedCubeMapLookup(reflDir).rgb * mix(vec3(1.0), materialTint, 0.82);
		float fresnel = clamp(pow(1.0 + dot(normalize(direction), normal), 2.0), 0.0, 1.0);

		specularSheen = rawReflectivity * (0.28 + 0.72 * fresnel);
	}

	bool shadedAsFoliage = isFoliage != 0;
	float directionalShadow = sampleSunShadow(direction, normal, length(mvVertexPos), shadedAsFoliage);
	float shadowFactor = combineSunAndCloudShadow(directionalShadow, sampleCloudShadow(direction));

	if (shadedAsFoliage && opaqueInLod != 0) {
		shadowFactor = mix(shadowFactor, 1.0, 0.65);
	}

	if (textureIndex == snowTextureIndex) {
		shadowFactor = mix(shadowFactor, 1.0, 0.60);
	}

	shadowFactor = mix(shadowFactor, 1.0, weatherShadowFade);

	vec3 effectiveSunLight = outSunLight;

	if (shadedAsFoliage) {
		vec3 lightDir = normalize(sunDirection);
		float NdotL = dot(normal, lightDir);

		float backLight = clamp(-NdotL, 0.0, 1.0);
		float sunLowness = 1.0 - clamp(abs(lightDir.z), 0.0, 1.0);
		float sssTranslucency = backLight * sunLowness * 0.18;
		float sssIntensity = mix(0.1, 1.0, dayNightFactor);

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

		fragColor.rgb += reflectionColor * pixelLight * specularSheen * 0.95;
	}

	if(!passDitherTest(fragColor.a)) discard;
	if (isFoliage != 0 || opaqueInLod == 0) {
		fragColor.a = texAlpha;
	} else {
		fragColor.a = 1;
	}
}
