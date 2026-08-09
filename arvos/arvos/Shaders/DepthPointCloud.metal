//
//  DepthPointCloud.metal
//  arvos
//
//  High-performance depth map to point cloud visualization
//  Based on Apple's ARKit scene depth best practices
//

#include <metal_stdlib>
#include "ParticleTypes.h"
using namespace metal;

// MARK: - Structs

struct DepthUniforms {
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
    float3x3 inverseIntrinsics;
    float4x4 localToWorld; // Camera transform from ARFrame
    float2 depthResolution;
    float pointSize;
    int confidenceThreshold; // 0=low, 1=medium, 2=high
};

struct ParticleVertexOut {
    float4 position [[position]];
    float3 color;
    float pointSize [[point_size]];
};

// MARK: - Unproject Depth to 3D Position

/// Unprojects a 2D depth pixel to 3D camera space using camera intrinsics
/// Based on Apple's ARKit sample: https://developer.apple.com/documentation/arkit/displaying-a-point-cloud-using-scene-depth
/// Formula: position = inverse(K) * [x, y, 1] * depth
float3 unprojectDepthSample(float2 pixelCoord,
                            float depth,
                            float3x3 inverseIntrinsics,
                            float2 depthResolution) {
    // Normalize to [0, 1] range
    float2 normalizedCoord = pixelCoord / depthResolution;
    (void)normalizedCoord; // Calculated for potential future use

    // Apply inverse intrinsics to get direction vector
    // The intrinsics matrix already contains focal length and principal point
    float3 direction = inverseIntrinsics * float3(pixelCoord.x, pixelCoord.y, 1.0);

    // Scale direction by depth to get 3D position
    // This converts from normalized direction to actual position in meters
    return direction * depth;
}

// MARK: - Vertex Shader

/// Vertex shader for depth point cloud rendering
/// Each vertex represents one depth pixel
vertex ParticleVertexOut depthPointCloudVertex(
    uint vertexID [[vertex_id]],
    constant DepthUniforms& uniforms [[buffer(0)]],
    texture2d<float, access::sample> depthTexture [[texture(0)]],
    texture2d<uint, access::sample> confidenceTexture [[texture(1)]],
    texture2d<float, access::sample> colorTexture [[texture(2)]]
) {
    ParticleVertexOut out;

    // Calculate 2D position in depth map
    uint depthWidth = uint(uniforms.depthResolution.x);

    uint x = vertexID % depthWidth;
    uint y = vertexID / depthWidth;
    float2 pixelCoord = float2(x, y);

    // Sample depth value using NORMALIZED coordinates [0, 1]
    constexpr sampler depthSampler(coord::normalized, filter::nearest);
    float2 texCoord = pixelCoord / uniforms.depthResolution;
    float depth = depthTexture.sample(depthSampler, texCoord).r;

    // Sample confidence (if available)
    uint confidence = 0;
    if (uniforms.confidenceThreshold >= 0) {
        confidence = confidenceTexture.sample(depthSampler, texCoord).r;

        // Filter by confidence threshold
        // ARFrameDepthConfidence: 0=low, 1=medium, 2=high
        if (int(confidence) < uniforms.confidenceThreshold) {
            // Discard low confidence points by moving off-screen
            out.position = float4(0, 0, -1000, 1);
            out.color = float3(0);
            out.pointSize = 0;
            return out;
        }
    }

    // Unproject depth to 3D camera-local space
    float3 localPosition = unprojectDepthSample(
        pixelCoord,
        depth,
        uniforms.inverseIntrinsics,
        uniforms.depthResolution
    );

    // Transform to world space for persistent visualization
    float4 worldPosition = uniforms.localToWorld * float4(localPosition, 1.0);

    // Perform homogeneous divide
    worldPosition = worldPosition / worldPosition.w;

    // Render in clip space
    out.position = uniforms.projectionMatrix * uniforms.viewMatrix * worldPosition;

    // Color based on depth - simple gradient for clarity
    // Map depth 0-2m to visible colors
    float normalizedDepth = saturate(depth / 2.0);

    // Red (close) -> Green (medium) -> Blue (far)
    float r = saturate(1.0 - normalizedDepth * 2.0);
    float g = saturate(1.0 - abs(normalizedDepth - 0.5) * 2.0);
    float b = saturate(normalizedDepth * 2.0 - 1.0);

    out.color = float3(r, g, b);

    // Fixed point size for now
    out.pointSize = uniforms.pointSize;

    return out;
}

// MARK: - Fragment Shader

/// Fragment shader for point cloud particles
fragment float4 depthPointCloudFragment(ParticleVertexOut in [[stage_in]],
                                         float2 pointCoord [[point_coord]]) {
    // Create circular particles
    float2 center = pointCoord - float2(0.5);
    float dist = length(center);

    // Smooth circle edge
    float alpha = 1.0 - smoothstep(0.4, 0.5, dist);

    if (alpha < 0.01) {
        discard_fragment();
    }

    return float4(in.color, alpha);
}
