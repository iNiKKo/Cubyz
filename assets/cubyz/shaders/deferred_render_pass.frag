#version 460

#include "frame_uniforms.glsl"

layout(location = 0) out vec4 fragColor;

layout(location = 0) in vec2 texCoords;
layout(location = 1) flat in vec3[4] directions;

layout(binding = 3) uniform sampler2D color;

layout(binding = 4) uniform sampler2D depthTexture;

layout(binding = 5) uniform sampler2D bloomColor;

layout(binding = 10) uniform sampler2D godRayColor;

layout(binding = 11) uniform sampler2D cloudColor;

layout(binding = 12) uniform sampler2D waterSurfaceColor;

layout(location = 1) uniform vec2 tanXY;
layout(location = 2) uniform float zNear;
layout(location = 3) uniform float zFar;
uniform vec3 godRayTint;
uniform float waterTime;

uniform float fogWhitening;

uniform float weatherFogStrength;

uniform float skyIslandGroundFade;
uniform float skyIslandMistStrength;
uniform vec3 skyIslandFogColor;

struct Fog {
	vec3 color;
	float density;
	float fogLower;
	float fogHigher;
};

layout(location = 6) uniform Fog fog;

float zFromDepth(float depthBufferValue) {
	return zNear*zFar/(depthBufferValue*(zNear - zFar) + zFar);
}

float densityIntegral(float dist, float zStart, float zDist, float fogLower, float fogHigher) {

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

float calculateFogDistance(float dist, float densityAdjustment, float playerWorldZ, float zScale, float fogDensity, float fogLower, float fogHigher) {
	float effectiveDist = dist * densityAdjustment;

	float fogStartFraction = mix(0.6, 0.22, weatherFogStrength);
	float fogEdgeMultiplier = mix(8.0, 14.0, weatherFogStrength);
	float fogStart = fogStartFraction / max(1e-5, fogDensity);
	float distFog = max(0.0, effectiveDist - fogStart) * fogDensity * fogEdgeMultiplier;

	float heightFog = densityIntegral(effectiveDist, playerWorldZ - playerPositionInteger.z, zScale * effectiveDist, fogLower - playerPositionInteger.z, fogHigher - playerPositionInteger.z) * fogDensity;

	float totalFog = max(distFog, heightFog);

	return -mix(totalFog, totalFog*totalFog, weatherFogStrength);
}

vec3 applyFrontfaceFog(float fogDistance, vec3 fogColor, vec3 inColor) {
	float fogFactor = exp(fogDistance);

	float fogOpacity = 1.0 - fogFactor;
	float fogColorBrightness = max(fogColor.r, max(fogColor.g, fogColor.b));
	vec3 desaturatedFogColor = vec3(fogColorBrightness);

	vec3 finalFogColor = (fog.fogLower > 1e9) ? fogColor : mix(fogColor, desaturatedFogColor, fogOpacity*fogOpacity*fogWhitening);
	inColor *= fogFactor;
	inColor += finalFogColor;
	inColor -= finalFogColor*fogFactor;
	return inColor;
}

void main() {
	vec2 sampleCoords = texCoords;
	if (fog.fogLower > 1e9) {
		float wave1 = sin(texCoords.x * 5.0 + texCoords.y * 3.5 + waterTime * 1.2);
		float wave2 = cos(texCoords.x * 3.5 - texCoords.y * 5.0 + waterTime * 0.9);
		vec2 refractionOffset = vec2(wave1 + wave2, wave1 - wave2) * 0.00025;
		sampleCoords = clamp(texCoords + refractionOffset, 0.0, 1.0);
	}
	fragColor = texture(color, sampleCoords);
	fragColor += texture(bloomColor, sampleCoords);
	if (godRayTint != vec3(0.0)) {
		fragColor.rgb += texture(godRayColor, sampleCoords).r * godRayTint;
	}
	vec2 clampedTexCoords = (floor(texCoords*vec2(textureSize(color, 0))) + 0.5)/vec2(textureSize(color, 0));
	vec3 direction = clampedTexCoords.x*(
		clampedTexCoords.y*directions[0] + (1 - clampedTexCoords.y)*directions[1]
	) + (1 - clampedTexCoords.x)*(
		clampedTexCoords.y*directions[2] + (1 - clampedTexCoords.y)*directions[3]
	);
	float rawDepth = texture(depthTexture, texCoords).r;

	if (rawDepth < 0.999999) {
		float densityAdjustment = sqrt(dot(tanXY*(clampedTexCoords*2 - 1), tanXY*(clampedTexCoords*2 - 1)) + 1);
		float dist = zFromDepth(rawDepth);
		float playerWorldZ = float(playerPositionInteger.z) + playerPositionFraction.z;
		float fogDistance = calculateFogDistance(dist, densityAdjustment, playerWorldZ, normalize(direction).z, fog.density, fog.fogLower - playerPositionInteger.z, fog.fogHigher - playerPositionInteger.z);
		fragColor.rgb = applyFrontfaceFog(fogDistance, fog.color, fragColor.rgb);
		if (fog.fogLower < 1e9 && skyIslandGroundFade > 0.0) {

			float eyeDistance = dist*densityAdjustment;
			float fragmentWorldZ = playerWorldZ + normalize(direction).z*eyeDistance;
			float lowGroundMask = 1.0 - smoothstep(1800.0, 3200.0, fragmentWorldZ);
			float aerialFade = skyIslandGroundFade*lowGroundMask;
			fragColor.rgb = mix(fragColor.rgb, skyIslandFogColor, aerialFade);
		}
		if (fog.fogLower < 1e9 && skyIslandMistStrength > 0.0) {

			float eyeDistance = dist*densityAdjustment;
			float silhouetteAbsorption = smoothstep(460.0, 1050.0, eyeDistance)*skyIslandMistStrength;
			fragColor.rgb = mix(fragColor.rgb, skyIslandFogColor, silhouetteAbsorption);
		}
		if (fog.fogLower > 1e9) {
			vec3 underwaterRay = normalize(direction);
			float underwaterLookingUp = smoothstep(-0.15, 0.75, underwaterRay.z);

			vec3 underwaterBackground = fog.color*mix(0.22, 0.72, underwaterLookingUp);

			float underwaterTransmission = exp(fogDistance);
			float silhouetteFade = 1.0 - smoothstep(0.20, 0.55, underwaterTransmission);
			fragColor.rgb = mix(fragColor.rgb, underwaterBackground, silhouetteFade);

			float eyeDistance = dist*densityAdjustment;
			float horizontalDistance = eyeDistance*length(underwaterRay.xy);
			float underwaterDrawCapFade = smoothstep(36.0, 64.0, horizontalDistance);

			fragColor.rgb = mix(fragColor.rgb, underwaterBackground, underwaterDrawCapFade);
		}
	} else {
		if (skyIslandMistStrength > 0.0) {

			vec3 darkerThanSky = max(skyIslandFogColor - fragColor.rgb, vec3(0.0));
			float msaaDarkEdge = clamp(max(darkerThanSky.r, max(darkerThanSky.g, darkerThanSky.b))*3.0, 0.0, 1.0);
			fragColor.rgb = mix(fragColor.rgb, skyIslandFogColor, msaaDarkEdge*skyIslandMistStrength);
		}
		if (fog.fogLower > 1e9) {

			vec3 underwaterDirection = normalize(direction);
			float lookingUp = smoothstep(-0.15, 0.75, underwaterDirection.z);

			vec3 underwaterSky = fog.color * mix(0.22, 0.72, lookingUp);
			fragColor.rgb = mix(fragColor.rgb, underwaterSky, 0.90);
		} else {

			vec3 normalizedDirection = normalize(direction);

			float horizonWallBand = 0.3;
			float horizonFactor = 1.0 - smoothstep(0.0, horizonWallBand, abs(normalizedDirection.z));
			if (horizonFactor > 0.0) {

				float wallDist = 1.0 / max(1e-5, fog.density);
				float fogDistance = calculateFogDistance(wallDist, 1.0, float(playerPositionInteger.z) + playerPositionFraction.z, normalizedDirection.z, fog.density, fog.fogLower - playerPositionInteger.z, fog.fogHigher - playerPositionInteger.z);

				vec3 walledColor = applyFrontfaceFog(fogDistance, fog.color, fragColor.rgb);
				fragColor.rgb = mix(fragColor.rgb, walledColor, horizonFactor);
			}
		}
	}
	vec4 clouds = texture(cloudColor, sampleCoords);
	fragColor.rgb = clouds.rgb + fragColor.rgb*(1.0 - clouds.a);

	if (rawDepth >= 0.999999 && weatherFogStrength > 0.001) {
		vec3 skyDirection = normalize(direction);
		float upwardness = smoothstep(-0.15, 0.55, skyDirection.z);

		float skyHaze = (1.0 - exp(-8.0*weatherFogStrength))*mix(0.65, 1.0, upwardness);
		fragColor.rgb = mix(fragColor.rgb, fog.color, skyHaze);
	}
	vec4 waterSurface = texture(waterSurfaceColor, sampleCoords);
	fragColor.rgb = waterSurface.rgb + fragColor.rgb*(1.0 - waterSurface.a);
	float maxColor = max(1.0, max(fragColor.r, max(fragColor.g, fragColor.b)));
	fragColor.rgb = fragColor.rgb/maxColor;
}
