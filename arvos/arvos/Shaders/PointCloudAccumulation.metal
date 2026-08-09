//
//  PointCloudAccumulation.metal
//  arvos
//
//  Compute shader for accumulating depth points into persistent buffer
//

#include <metal_stdlib>
#include "ParticleTypes.h"
using namespace metal;

struct AccumulationUniforms {
    float3x3 cameraIntrinsicsInversed;
    float4x4 localToWorld;
    float2 depthResolution;
    int pointCloudCurrentIndex;
    int maxPoints;
    int confidenceThreshold;
};

constexpr sampler textureSampler(coord::normalized, filter::nearest);

/// Retrieves the world position of a specified camera point with depth
static float4 worldPoint(float2 cameraPoint, float depth, float3x3 cameraIntrinsicsInversed, float4x4 localToWorld) {
    const auto localPoint = cameraIntrinsicsInversed * float3(cameraPoint, 1) * depth;
    const auto worldPoint = localToWorld * float4(localPoint, 1);

    return worldPoint / worldPoint.w;
}

/// Compute shader that accumulates depth points into particle buffer
kernel void accumulateDepthPoints(uint2 gid [[thread_position_in_grid]],
                                   constant AccumulationUniforms &uniforms [[buffer(0)]],
                                   device Particle *particles [[buffer(1)]],
                                   texture2d<float, access::sample> depthTexture [[texture(0)]],
                                   texture2d<uint, access::sample> confidenceTexture [[texture(1)]]) {

    // Subsample: Only process every 2nd pixel in each dimension (4x reduction)
    const uint2 subsampledGid = gid * 2;

    // Calculate point index
    const uint width = uint(uniforms.depthResolution.x);
    const uint height = uint(uniforms.depthResolution.y);

    if (subsampledGid.x >= width || subsampledGid.y >= height) {
        return;
    }

    const uint linearIndex = gid.y * (width / 2) + gid.x;
    const uint particleIndex = (uniforms.pointCloudCurrentIndex + linearIndex) % uniforms.maxPoints;

    // Sample depth using subsampled coordinates
    const float2 texCoord = float2(subsampledGid) / uniforms.depthResolution;
    const float depth = depthTexture.sample(textureSampler, texCoord).r;

    // Sample confidence
    const uint confidence = confidenceTexture.sample(textureSampler, texCoord).r;

    // Filter by confidence
    if (int(confidence) < uniforms.confidenceThreshold) {
        particles[particleIndex].confidence = 0.0;
        return;
    }

    // Calculate world position using subsampled coordinates
    const float2 cameraPoint = float2(subsampledGid);
    const float4 position = worldPoint(cameraPoint, depth, uniforms.cameraIntrinsicsInversed, uniforms.localToWorld);

    // Color based on depth
    float normalizedDepth = saturate(depth / 2.0);
    float r = saturate(1.0 - normalizedDepth * 2.0);
    float g = saturate(1.0 - abs(normalizedDepth - 0.5) * 2.0);
    float b = saturate(normalizedDepth * 2.0 - 1.0);

    // Write to particle buffer
    particles[particleIndex].position = position.xyz;
    particles[particleIndex].color = float3(r, g, b);
    particles[particleIndex].confidence = float(confidence);
}
