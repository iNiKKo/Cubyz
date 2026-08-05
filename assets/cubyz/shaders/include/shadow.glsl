
layout(binding = 6) uniform sampler2DShadow csmMap0;
layout(binding = 7) uniform sampler2DShadow csmMap1;
layout(binding = 8) uniform sampler2DShadow csmMap2;

layout(location = 44) uniform mat4 csmLightSpaceMatrix[3];

layout(location = 47) uniform float csmCascadeFar[3];

layout(location = 50) uniform vec3 csmTexelSize;

layout(location = 33) uniform bool shadowsEnabled;
// 0 = full night, 1 = full day, smoothly ramped across the horizon crossing - see
// DayTime.dayNightFactor() (src/game.zig). Replaces a hard isSunlight boolean that used to snap
// shadowAmbientFloorDay/Night instantly and caused a visible flicker right at sunrise/sunset.
layout(location = 38) uniform float dayNightFactor;
layout(location = 37) uniform vec3 sunDirection;
layout(location = 39) uniform float shadowDarkness;

layout(location = 51) uniform float shadowTransitionFade;

layout(location = 52) uniform int csmActiveCascades;

layout(location = 34) uniform vec2 cloudCoverageOrigin;
layout(location = 35) uniform float cloudCoverageWorldSize;
layout(location = 36) uniform float cloudHeightRelative;

const float shadowAmbientFloorDay = 0.55;
const float shadowAmbientFloorNight = 0.78;

const vec2 poissonDisk[9] = vec2[](
	vec2( 0.000,  0.000),
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

const float PCF_KERNEL_RADIUS_C0 = 4.2;
const float PCF_KERNEL_RADIUS_C1 = 2.0;
const float PCF_KERNEL_RADIUS_C2 = 4.2;

float shadowKernelRotationAngle() {
	vec2 uv = gl_FragCoord.xy;
	float n = fract(52.9829189 * fract(dot(uv, vec2(0.06711056, 0.00583715))));
	return n * 6.2831853;
}

float sampleCascadePCF(int cascade, sampler2DShadow shadowMap, vec3 projCoords, float kernelRadius, bool noRotation) {

	float angle = noRotation ? 0.0 : shadowKernelRotationAngle();
	float s = sin(angle);
	float cAngle = cos(angle);
	float shadow = 0.0;
	for (int i = 0; i < 9; ++i) {
		vec2 diskPoint = poissonDisk[i];
		vec2 offset = vec2(diskPoint.x*cAngle - diskPoint.y*s, diskPoint.x*s + diskPoint.y*cAngle) * kernelRadius * csmTexelSize[cascade];
		shadow += texture(shadowMap, vec3(projCoords.xy + offset, projCoords.z));
	}
	return shadow / 9.0;
}

float sampleCascade(int cascade, vec3 worldPosRelative, vec3 normal, float tanTheta, bool isFoliage) {

	bool isCrossQuadFoliage = isFoliage && abs(normal.z) < 0.9;
	bool isThinHorizontalFoliage = isFoliage && abs(normal.z) > 0.55;
	float blockTopRelativeZ = worldPosRelative.z - fract(worldPosRelative.z + playerPositionFraction.z) + 1.0;
	vec3 shadowTestPos = isCrossQuadFoliage ? vec3(worldPosRelative.xy, blockTopRelativeZ) : worldPosRelative;

	const float normalOffsetBase = 0.02;

	vec3 offsetPos = isCrossQuadFoliage ? shadowTestPos : (worldPosRelative + normal * (normalOffsetBase * (1.0 + float(cascade) * 0.5)));

	if (isThinHorizontalFoliage) offsetPos += normal*0.055;
	vec4 lightSpacePos = csmLightSpaceMatrix[cascade] * vec4(offsetPos, 1.0);
	vec3 projCoords = lightSpacePos.xyz / lightSpacePos.w;
	projCoords = projCoords * 0.5 + 0.5;

	if (any(lessThan(projCoords, vec3(0.001))) || any(greaterThan(projCoords, vec3(0.999)))) {
		return 1.0;
	}

	float cascadeDepthRange = 2.0*csmCascadeFar[cascade] + (cascade == 0 ? 128.0 : (cascade == 1 ? 288.0 : 1056.0));
	float biasBlocks = mix(0.010, 0.030, clamp(tanTheta/3.0, 0.0, 1.0));
	float bias = biasBlocks/max(cascadeDepthRange, 1.0);
	projCoords.z -= bias;

	float foliageKernelBoost = isFoliage ? 1.4 : 1.0;
	if (cascade == 0) return sampleCascadePCF(0, csmMap0, projCoords, PCF_KERNEL_RADIUS_C0 * foliageKernelBoost, isFoliage);
	else if (cascade == 1) return sampleCascadePCF(1, csmMap1, projCoords, PCF_KERNEL_RADIUS_C1 * foliageKernelBoost, isFoliage);

	else return sampleCascadePCF(2, csmMap2, projCoords, PCF_KERNEL_RADIUS_C2 * foliageKernelBoost, isFoliage);
}

float sampleSunShadow(vec3 worldPosRelative, vec3 normal, float cameraDepth, bool isFoliage) {
	if (!shadowsEnabled) return 1.0;

	vec3 lightDir = sunDirection;
	float baseAmbientFloor = mix(shadowAmbientFloorNight, shadowAmbientFloorDay, dayNightFactor);
	float shadowAmbientFloor = (shadowDarkness <= 0.5)
		? mix(1.0, baseAmbientFloor, shadowDarkness * 2.0)
		: mix(baseAmbientFloor, baseAmbientFloor * 0.2, (shadowDarkness - 0.5) * 2.0);

	bool isCrossQuadFoliage = isFoliage && abs(normal.z) < 0.9;

	float NdotL = dot(normal, lightDir);
	if (!isCrossQuadFoliage && NdotL <= 0.001) return shadowAmbientFloor;

	int cascade = 0;
	if (cameraDepth > csmCascadeFar[0]) cascade = 1;
	if (cameraDepth > csmCascadeFar[1]) cascade = 2;
	cascade = min(cascade, csmActiveCascades - 1);

	float absNdotL = max(abs(NdotL), 0.05);
	float sinTheta = sqrt(1.0 - clamp(absNdotL * absNdotL, 0.0, 1.0));
	float tanTheta = clamp(sinTheta / absNdotL, 0.0, 3.0);

	float light = sampleCascade(cascade, worldPosRelative, normal, tanTheta, isFoliage);

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

	float horizonFade = smoothstep(0.02, 0.18, abs(sunDirection.z));
	float finalShadow = mix(shadowAmbientFloor, 1.0, light);
	finalShadow = mix(1.0, finalShadow, horizonFade);
	return mix(1.0, finalShadow, shadowTransitionFade);
}

layout(binding = 9) uniform sampler2D cloudCoverageTex;
const float cloudShadowStrength = 0.3;

float sampleCloudShadow(vec3 worldPosRelative) {
	if (!shadowsEnabled) return 1.0;
	if (sunDirection.z <= 0.001) return 1.0;

	float t = (cloudHeightRelative - worldPosRelative.z)/sunDirection.z;
	if (t <= 0.0) return 1.0;

	vec2 samplePos = worldPosRelative.xy + sunDirection.xy*t;
	vec2 uv = (samplePos - cloudCoverageOrigin)/cloudCoverageWorldSize;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return 1.0;

	float distFromPlayer = length(samplePos);
	float halfExtent = cloudCoverageWorldSize*0.5;
	float distanceFade = 1.0 - smoothstep(halfExtent*0.4, halfExtent*0.9, distFromPlayer);

	float coverage = texture(cloudCoverageTex, uv).r;
	float shadow = 1.0 - smoothstep(0.45, 0.65, coverage)*cloudShadowStrength*distanceFade;
	return shadow;
}

float combineSunAndCloudShadow(float sunShadow, float cloudShadow) {

	float cloudCoverage = clamp((1.0 - cloudShadow)/cloudShadowStrength, 0.0, 1.0);
	float diffusedSunShadow = mix(sunShadow, 1.0, cloudCoverage*0.70);
	return diffusedSunShadow*cloudShadow;
}
