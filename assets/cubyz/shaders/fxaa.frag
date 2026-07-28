#version 460

// Standard luma-edge-detection FXAA (a la Timothy Lottes' FXAA 3.11), operating on the final
// composited LDR image. Runs last, after deferred_render_pass has already tonemapped/composited
// bloom+god-rays+fog, so it also smooths the aliased silhouettes of alpha-cutout foliage (distant
// tree canopies made of many small hard-edged leaf quads) which this engine has no other mechanism
// to anti-alias against (no MSAA on the deferred/HDR path, no TAA).

layout(location = 0) out vec4 fragColor;

layout(location = 0) in vec2 texCoords;

layout(binding = 3) uniform sampler2D image;

layout(location = 0) uniform vec2 inverseScreenSize;

const float edgeThresholdMin = 0.0625; // Skip pixels darker/flatter than this contrast (avoids blurring flat shadows).
const float edgeThresholdMax = 0.166; // Contrast above this is always considered an edge.
// Sub-pixel smoothing additionally blurs based on local 3x3 luma deviation, not just the directional
// edge search — this is what catches thin/specular aliasing, but it can't distinguish "jagged edge"
// from "dense fine texture detail" (e.g. distant tree canopies made of many small leaf quads), so a
// high value here reads as an out-of-focus blur on exactly that kind of high-frequency foliage detail
// rather than fixing aliasing. Kept low so FXAA only cleans up actual silhouette jaggies and mostly
// leaves foliage-density detail alone, rather than smearing it into a soft blob.
const float subpixelQuality = 0.25;
const int iterations = 12;

float luma(vec3 rgb) {
	return dot(rgb, vec3(0.299, 0.587, 0.114));
}

void main() {
	vec3 colorCenter = texture(image, texCoords).rgb;

	float lumaCenter = luma(colorCenter);
	float lumaDown = luma(textureOffset(image, texCoords, ivec2(0, -1)).rgb);
	float lumaUp = luma(textureOffset(image, texCoords, ivec2(0, 1)).rgb);
	float lumaLeft = luma(textureOffset(image, texCoords, ivec2(-1, 0)).rgb);
	float lumaRight = luma(textureOffset(image, texCoords, ivec2(1, 0)).rgb);

	float lumaMin = min(lumaCenter, min(min(lumaDown, lumaUp), min(lumaLeft, lumaRight)));
	float lumaMax = max(lumaCenter, max(max(lumaDown, lumaUp), max(lumaLeft, lumaRight)));
	float lumaRange = lumaMax - lumaMin;

	if(lumaRange < max(edgeThresholdMin, lumaMax*edgeThresholdMax)) {
		fragColor = vec4(colorCenter, 1.0);
		return;
	}

	float lumaDownLeft = luma(textureOffset(image, texCoords, ivec2(-1, -1)).rgb);
	float lumaUpRight = luma(textureOffset(image, texCoords, ivec2(1, 1)).rgb);
	float lumaUpLeft = luma(textureOffset(image, texCoords, ivec2(-1, 1)).rgb);
	float lumaDownRight = luma(textureOffset(image, texCoords, ivec2(1, -1)).rgb);

	float lumaDownUp = lumaDown + lumaUp;
	float lumaLeftRight = lumaLeft + lumaRight;

	float lumaLeftCorners = lumaDownLeft + lumaUpLeft;
	float lumaDownCorners = lumaDownLeft + lumaDownRight;
	float lumaRightCorners = lumaDownRight + lumaUpRight;
	float lumaUpCorners = lumaUpRight + lumaUpLeft;

	float edgeHorizontal = abs(-2.0*lumaLeft + lumaLeftCorners) + abs(-2.0*lumaCenter + lumaDownUp)*2.0 + abs(-2.0*lumaRight + lumaRightCorners);
	float edgeVertical = abs(-2.0*lumaUp + lumaUpCorners) + abs(-2.0*lumaCenter + lumaLeftRight)*2.0 + abs(-2.0*lumaDown + lumaDownCorners);
	bool isHorizontal = edgeHorizontal >= edgeVertical;

	float luma1 = isHorizontal ? lumaDown : lumaLeft;
	float luma2 = isHorizontal ? lumaUp : lumaRight;
	float gradient1 = luma1 - lumaCenter;
	float gradient2 = luma2 - lumaCenter;
	bool is1Steepest = abs(gradient1) >= abs(gradient2);
	float gradientScaled = 0.25*max(abs(gradient1), abs(gradient2));

	float stepLength = isHorizontal ? inverseScreenSize.y : inverseScreenSize.x;
	float lumaLocalAverage = 0.0;
	if(is1Steepest) {
		stepLength = -stepLength;
		lumaLocalAverage = 0.5*(luma1 + lumaCenter);
	} else {
		lumaLocalAverage = 0.5*(luma2 + lumaCenter);
	}

	vec2 currentUv = texCoords;
	if(isHorizontal) {
		currentUv.y += stepLength*0.5;
	} else {
		currentUv.x += stepLength*0.5;
	}

	vec2 offset = isHorizontal ? vec2(inverseScreenSize.x, 0.0) : vec2(0.0, inverseScreenSize.y);
	vec2 uv1 = currentUv - offset;
	vec2 uv2 = currentUv + offset;

	float lumaEnd1 = luma(texture(image, uv1).rgb) - lumaLocalAverage;
	float lumaEnd2 = luma(texture(image, uv2).rgb) - lumaLocalAverage;
	bool reached1 = abs(lumaEnd1) >= gradientScaled;
	bool reached2 = abs(lumaEnd2) >= gradientScaled;
	bool reachedBoth = reached1 && reached2;

	if(!reached1) uv1 -= offset;
	if(!reached2) uv2 += offset;

	for(int i = 0; i < iterations && !reachedBoth; i++) {
		if(!reached1) {
			lumaEnd1 = luma(texture(image, uv1).rgb) - lumaLocalAverage;
		}
		if(!reached2) {
			lumaEnd2 = luma(texture(image, uv2).rgb) - lumaLocalAverage;
		}
		reached1 = abs(lumaEnd1) >= gradientScaled;
		reached2 = abs(lumaEnd2) >= gradientScaled;
		reachedBoth = reached1 && reached2;
		if(!reached1) uv1 -= offset;
		if(!reached2) uv2 += offset;
	}

	float distance1 = isHorizontal ? (texCoords.x - uv1.x) : (texCoords.y - uv1.y);
	float distance2 = isHorizontal ? (uv2.x - texCoords.x) : (uv2.y - texCoords.y);

	bool isDirection1 = distance1 < distance2;
	float distanceFinal = min(distance1, distance2);
	float edgeThickness = distance1 + distance2;
	float pixelOffset = -distanceFinal/edgeThickness + 0.5;

	bool isLumaCenterSmaller = lumaCenter < lumaLocalAverage;
	bool correctVariation = ((isDirection1 ? lumaEnd1 : lumaEnd2) < 0.0) != isLumaCenterSmaller;
	float finalOffset = correctVariation ? pixelOffset : 0.0;

	// Sub-pixel antialiasing: additionally blur based on how far the local 3x3 average luma deviates
	// from a simple box blur — catches thin geometry (grass blades, leaf edges) the edge search above
	// can miss since that search only follows the single dominant gradient direction.
	float lumaAverage = (1.0/12.0)*(2.0*(lumaDownUp + lumaLeftRight) + lumaLeftCorners + lumaRightCorners);
	float subPixelOffset1 = clamp(abs(lumaAverage - lumaCenter)/lumaRange, 0.0, 1.0);
	float subPixelOffset2 = (-2.0*subPixelOffset1 + 3.0)*subPixelOffset1*subPixelOffset1;
	float subPixelOffsetFinal = subPixelOffset2*subPixelOffset2*subpixelQuality;

	finalOffset = max(finalOffset, subPixelOffsetFinal);

	vec2 finalUv = texCoords;
	if(isHorizontal) {
		finalUv.y += finalOffset*stepLength;
	} else {
		finalUv.x += finalOffset*stepLength;
	}

	fragColor = vec4(texture(image, finalUv).rgb, 1.0);
}
