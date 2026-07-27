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
uniform float handLightRadius;

layout(std430, binding = 1) buffer _animatedTexture
{
	float animatedTexture[];
};

#include "shadow.glsl"

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
	if (handLightRadius == 0) return vec3(0);

	// Deliberately omnidirectional (no surface-normal/cosine term) — matches entity_fragment.frag's
	// handLightContribution exactly. A held torch previously used a Lambertian (normal-facing-the-light)
	// falloff here, which left any surface not roughly facing the torch (a block's top face when the
	// torch is held at chest height and to the side, a wall behind you, etc.) completely unlit — no
	// bounce/ambient term existed to fill that in, so it read as patches of pitch black right next to a
	// lit torch. A *placed* light doesn't have this problem: its blockLight is a single flood-filled
	// scalar per voxel cell, applied identically to every face of that cell regardless of which way it
	// points, which is what makes it look like it's softly filling the whole area (closer to bounced
	// light) rather than only lighting directly-facing surfaces. Dropping the cosine term here can't
	// replicate real bounce lighting, but it removes the direction-dependent blackout and makes the held
	// torch read consistently with both the placed-light look and entities' own held-item light.
	float dist = length(direction - handLightPositionRelative);
	float atten = clamp(1.0 - dist/handLightRadius, 0.0, 1.0);
	return handLightColor*sqrt(atten); // gentler than atten*atten — stays bright through most of the radius, only tapers sharply near the edge
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
	float normalVariation = (opaqueInLod == 0) ? 1.0 : lightVariation(normal);
	vec3 textureCoords = vec3(uv, animatedTextureIndex);

	float reflectivity = texture(reflectivityAndAbsorptionSampler, textureCoords).a;
	float fresnelReflection = (1 + dot(normalize(direction), normal));
	fresnelReflection *= fresnelReflection;
	fresnelReflection *= min(1, 2*reflectivity); // Limit it to 2*reflectivity to avoid making every block reflective.
	reflectivity = reflectivity*fixedCubeMapLookup(reflect(direction, normal)).x;
	reflectivity = reflectivity*(1 - fresnelReflection) + fresnelReflection;

	bool isFoliage = opaqueInLod == 0;
	float shadowFactor = sampleSunShadow(direction, normal, length(mvVertexPos), isFoliage)*sampleCloudShadow(direction);

	vec3 effectiveSunLight = outSunLight;
	// Subsurface Scattering (SSS) / Translucency for foliage (grass blades, flowers, crops):
	// Direct sunlight penetrating thin plant tissue causes the back face of grass to glow brightly.
	// Applied to outSunLight only (not outBlockLight) — this is specifically light passing through leaf
	// tissue from the sun/moon side, a torch's blockLight doesn't participate.
	if (isFoliage) {
		vec3 lightDir = normalize(sunDirection);
		float NdotL = dot(normal, lightDir);
		float sssTranslucency = clamp(0.5 - 0.5 * NdotL, 0.0, 0.25);
		float sssIntensity = isSunlight ? 1.0 : 0.1;
		float rootAO = mix(0.70, 1.0, smoothstep(0.0, 0.4, min(uv.y, 1.0 - uv.y)));
		effectiveSunLight = outSunLight * (1.0 + sssTranslucency * sssIntensity) * rootAO;
	}

	vec3 totalLight = min(max(max(effectiveSunLight*shadowFactor, outBlockLight), handLightContribution()), vec3(1));
	vec3 pixelLight = max(totalLight*normalVariation, texture(emissionSampler, textureCoords).r*4);
	fragColor = texture(textureSampler, textureCoords)*vec4(pixelLight, 1);
	fragColor.rgb += reflectivity*pixelLight;

	if(!passDitherTest(fragColor.a)) discard;
	fragColor.a = 1;
}
