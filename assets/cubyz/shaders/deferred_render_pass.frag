#version 460

#include "frame_uniforms.glsl"

layout(location = 0) out vec4 fragColor;

layout(location = 0) in vec2 texCoords;
layout(location = 1) flat in vec3[4] directions;

layout(binding = 3) uniform sampler2D color;

layout(binding = 4) uniform sampler2D depthTexture;

layout(binding = 5) uniform sampler2D bloomColor;

layout(binding = 10) uniform sampler2D godRayColor;
// Premultiplied translucent cloud RGB + alpha, rendered separately from opaque terrain depth.
layout(binding = 11) uniform sampler2D cloudColor;

layout(location = 1) uniform vec2 tanXY;
layout(location = 2) uniform float zNear;
layout(location = 3) uniform float zFar;
uniform vec3 godRayTint;
uniform float waterTime;
// 1 = legacy pale/desaturated LOD haze; 0 = preserve the supplied fog hue for weather.
uniform float fogWhitening;
// 0 = ordinary LOD fog; weather increases both near-range haze and distant falloff.
uniform float weatherFogStrength;

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

float calculateFogDistance(float dist, float densityAdjustment, float playerWorldZ, float zScale, float fogDensity, float fogLower, float fogHigher) {
	float effectiveDist = dist * densityAdjustment;

	// Distance fog starts at 60% of total max LOD distance (all closer chunks are 100% crystal clear) and
	// ramps up to hide the outer edge of all loaded LOD chunks. Player-reported "the fog at the ends of
	// the LOD (furthest chunks) isn't there or is very weak" was correct: with the previous 0.75 start
	// fraction and 3.5 multiplier, terrain right at the actual edge of the loaded world was still ~42%
	// visible (totalFog = (1-0.75)*3.5 = 0.875, fogFactor = exp(-0.875) ≈ 0.417) — a mild haze, not enough
	// to hide chunks actually disappearing/popping in at the render-distance boundary. Tuned so the ramp
	// starts earlier (0.6, giving more distance to fade smoothly rather than a sudden wall) and reaches
	// ~4% visibility exactly at the edge (totalFog = (1-0.6)*8.0 = 3.2, fogFactor = exp(-3.2) ≈ 0.041).
	// Storm visibility needs to close before distant terrain can remain a readable mountain silhouette.
	// The clear-weather LOD fade is unchanged; only local weather moves the start nearer and steepens it.
	float fogStartFraction = mix(0.6, 0.22, weatherFogStrength);
	float fogEdgeMultiplier = mix(8.0, 14.0, weatherFogStrength);
	float fogStart = fogStartFraction / max(1e-5, fogDensity);
	float distFog = max(0.0, effectiveDist - fogStart) * fogDensity * fogEdgeMultiplier;

	// Height fog (mist layer near ground):
	float heightFog = densityIntegral(effectiveDist, playerWorldZ - playerPositionInteger.z, zScale * effectiveDist, fogLower - playerPositionInteger.z, fogHigher - playerPositionInteger.z) * fogDensity;

	float totalFog = max(distFog, heightFog);
	// Ordinary LOD fog keeps its familiar exponential curve. Rain/snow/dust progressively move toward
	// an exponential-squared tail: near terrain stays readable, but distant ridges cannot remain as a
	// sharp silhouette through a strong storm.
	return -mix(totalFog, totalFog*totalFog, weatherFogStrength);
}

vec3 applyFrontfaceFog(float fogDistance, vec3 fogColor, vec3 inColor) {
	float fogFactor = exp(fogDistance);
	// Whiten the fog color itself as opacity (1 - fogFactor) rises, instead of using pure fog.color (sky
	// blue in the normal outdoor case, renderer.zig's fogColor = skyColorVal) all the way to full opacity.
	// Blending sky-blue fog into sky-blue background is a visual no-op right where it matters most — at
	// the render-distance edge, where fog is supposed to be hiding the world's actual boundary (terrain
	// disappearing, the vertical sphere-shaped render-volume gap, or here, the far side of a distant cloud
	// fading into the horizon) but instead reads as barely-there haze. Confirmed by the player on two
	// separate symptoms this affects: the original "isn't there or is very weak" edge-of-render-distance
	// report, and later a screenshot showing distant clouds' far side rendering distinctly blue while
	// their near side (less fogged) correctly stayed white — "it's not meant to be blue but foggy/misty."
	// A real, thick atmospheric haze reads as whitish/desaturated relative to the *ambient* sky color —
	// this ramps toward that look as fog opacity approaches 1, while barely affecting close-up, lightly-
	// fogged pixels (opacity near 0) so ordinary short-range height/distance fog still uses the tuned
	// fog.color exactly as before.
	//
	float fogOpacity = 1.0 - fogFactor;
	float fogColorBrightness = max(fogColor.r, max(fogColor.g, fogColor.b));
	vec3 desaturatedFogColor = vec3(fogColorBrightness);

	// Block/underwater fog (fogLower > 1e9) uses pure fogColor so deep water stays rich ocean blue
	// without desaturating into monochrome gray.
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
	// Only apply terrain/height fog to actual world geometry (rawDepth < 0.99999).
	// Open sky background pixels (depth = 1.0) contain the skybox, stars, sun, and moon
	// which sit in outer space and must never be overwritten by atmospheric fog:
	if (rawDepth < 0.999999) {
		float densityAdjustment = sqrt(dot(tanXY*(clampedTexCoords*2 - 1), tanXY*(clampedTexCoords*2 - 1)) + 1);
		float dist = zFromDepth(rawDepth);
		float playerWorldZ = float(playerPositionInteger.z) + playerPositionFraction.z;
		float fogDistance = calculateFogDistance(dist, densityAdjustment, playerWorldZ, normalize(direction).z, fog.density, fog.fogLower - playerPositionInteger.z, fog.fogHigher - playerPositionInteger.z);
		fragColor.rgb = applyFrontfaceFog(fogDistance, fog.color, fragColor.rgb);
	} else {
		if (fog.fogLower > 1e9) {
			// Submerged underwater: smooth water tint for sky without circular mask shapes
			fragColor.rgb = mix(fragColor.rgb, fog.color, 0.35);
		} else {
			// Loaded terrain forms a sphere around the player (see mesh_storage.zig's isInRenderDistance),
			// not a cylinder: vertical chunk coverage shrinks toward zero right at the horizontal edge of
			// render distance, so looking roughly toward the horizon at that edge shows open sky where
			// terrain should still exist far below/above — like standing between a floor and a ceiling with
			// no walls, so the edge of either surface reveals open space straight through. This "fog wall"
			// closes that gap by fogging sky pixels too, but ONLY for near-horizontal view directions (where
			// the missing-geometry seam is actually visible) — looking straight up/down still shows real,
			// unfogged sky/stars, since there's no seam to hide in those directions.
			vec3 normalizedDirection = normalize(direction);
			// 1 when looking dead level, fading to 0 within horizonWallBand of straight up/down:
			float horizonWallBand = 0.3;
			float horizonFactor = 1.0 - smoothstep(0.0, horizonWallBand, abs(normalizedDirection.z));
			if (horizonFactor > 0.0) {
				// Reuse the same distance-fog ramp terrain already fades out with, so the wall's fog density
				// visually matches the terrain fog it's meeting at the seam instead of introducing a second,
				// differently-tuned fog effect. A sky ray has no real depth, so use a fixed distance beyond
				// where terrain fog is already ~100% opaque (calculateFogDistance's own fogStartFraction/
				// fogEdgeMultiplier tuning, see above) rather than reconstructing an actual intersection point.
				float wallDist = 1.0 / max(1e-5, fog.density);
				float fogDistance = calculateFogDistance(wallDist, 1.0, float(playerPositionInteger.z) + playerPositionFraction.z, normalizedDirection.z, fog.density, fog.fogLower - playerPositionInteger.z, fog.fogHigher - playerPositionInteger.z);
				// In the normal outdoor case fog.color IS the sky color (see renderer.zig's fogColor =
				// skyColorVal), so blending sky-colored fog into sky produces literally no visible wall — just
				// confirmed in-game ("the colour of the fog is the exact same as the sky, so it's not exactly
				// hiding the gap just kinda blurs it"). A real atmospheric haze reads as whitish/desaturated,
				// not sky-blue — applyFrontfaceFog itself now whitens fogColor as opacity rises (added after
				// this wall was first shipped, once the same sky-blue-into-sky-blue problem turned out to also
				// affect ordinary terrain fog on distant clouds — see that function's doc comment), so this
				// wall no longer needs its own separate whitening; passing fog.color straight through here
				// keeps this branch consistent with the ordinary terrain-fog branch above it.
				vec3 walledColor = applyFrontfaceFog(fogDistance, fog.color, fragColor.rgb);
				fragColor.rgb = mix(fragColor.rgb, walledColor, horizonFactor);
			}
		}
	}
	vec4 clouds = texture(cloudColor, sampleCoords);
	fragColor.rgb = clouds.rgb + fragColor.rgb*(1.0 - clouds.a);
	// Storms need a true overhead haze as well as ground-distance fog. Cloud geometry intentionally stays
	// translucent, so exposing every voxel/planar layer through a clear sky is distracting and physically
	// backwards: looking upward through precipitation should converge into the same overcast atmosphere.
	// Apply only where the opaque depth is open sky; terrain keeps its normal depth-derived weather fog.
	if (rawDepth >= 0.999999 && weatherFogStrength > 0.001) {
		vec3 skyDirection = normalize(direction);
		float upwardness = smoothstep(-0.15, 0.55, skyDirection.z);
		// Deliberately dense: this is the storm's opaque-looking overcast ceiling, not gentle fair-weather
		// distance haze. Even drizzle should conceal most of the layered cloud geometry overhead.
		float skyHaze = (1.0 - exp(-8.0*weatherFogStrength))*mix(0.65, 1.0, upwardness);
		fragColor.rgb = mix(fragColor.rgb, fog.color, skyHaze);
	}
	float maxColor = max(1.0, max(fragColor.r, max(fragColor.g, fragColor.b)));
	fragColor.rgb = fragColor.rgb/maxColor;
}
