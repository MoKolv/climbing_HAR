//
//  DepthPointCloudSimple.metal
//  arvos
//
//  Simple real-time depth visualization (matches Apple's approach)
//

#include <metal_stdlib>
using namespace metal;

struct PointCloudUniforms {
    float4x4 viewProjectionMatrix;
    float fx;
    float fy;
    float cx;
    float cy;
    float2 depthResolution;
    float pointSize;
    int confidenceThreshold;
};

struct PointVertexOut {
    float4 position [[position]];
    float4 color;
    float pointSize [[point_size]];
};

/// Simple vertex shader - unprojects depth in camera space (like Apple's sample)
vertex PointVertexOut simplePointCloudVertex(
    uint vertexID [[vertex_id]],
    constant PointCloudUniforms& uniforms [[buffer(0)]],
    texture2d<float, access::read> depthTexture [[texture(0)]],
    texture2d<uint, access::read> confidenceTexture [[texture(1)]]
) {
    PointVertexOut out;

    // Calculate 2D position
    uint width = uint(uniforms.depthResolution.x);
    uint2 pos;
    pos.y = vertexID / width;
    pos.x = vertexID % width;

    // Subsample: Only render every 2nd pixel for point cloud look
    if (pos.x % 2 != 0 || pos.y % 2 != 0) {
        out.position = float4(0, 0, -1000, 1);
        out.color = float4(0);
        out.pointSize = 0;
        return out;
    }

    // Read depth and convert to millimeters (like Apple's sample)
    float depth = depthTexture.read(pos).x * 1000.0f;

    // Read confidence
    uint confidence = confidenceTexture.read(pos).r;

    // Filter by confidence and invalid depth (< 1mm)
    if (int(confidence) < uniforms.confidenceThreshold || depth < 1.0) {
        out.position = float4(0, 0, -1000, 1);
        out.color = float4(0);
        out.pointSize = 0;
        return out;
    }

    // Unproject to camera-local 3D coordinates (Apple's formula)
    float xrw = (float(pos.x) - uniforms.cx) * depth / uniforms.fx;
    float yrw = (float(pos.y) - uniforms.cy) * depth / uniforms.fy;
    float4 cameraSpacePos = float4(xrw, yrw, depth, 1.0);

    // Transform to clip space
    out.position = uniforms.viewProjectionMatrix * cameraSpacePos;

    // Color based on depth (depth is in millimeters, so 3000mm = 3m max range)
    float normalizedDepth = saturate(depth / 3000.0);
    float r = saturate(1.0 - normalizedDepth * 2.0);
    float g = saturate(1.0 - abs(normalizedDepth - 0.5) * 2.0);
    float b = saturate(normalizedDepth * 2.0 - 1.0);
    out.color = float4(r, g, b, 1.0);

    out.pointSize = uniforms.pointSize;

    return out;
}

/// Fragment shader for points
fragment float4 simplePointCloudFragment(PointVertexOut in [[stage_in]],
                                          float2 pointCoord [[point_coord]]) {
    // Circular points
    float2 center = pointCoord - float2(0.5);
    float dist = length(center);
    float alpha = 1.0 - smoothstep(0.4, 0.5, dist);

    if (alpha < 0.01) {
        discard_fragment();
    }

    return float4(in.color.rgb, alpha * in.color.a);
}
