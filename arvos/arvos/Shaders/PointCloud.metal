//
//  PointCloud.metal
//  arvos
//
//  Metal shaders for point cloud rendering
//

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 modelViewProjectionMatrix;
};

struct VertexOut {
    float4 position [[position]];
    float3 color;
    float pointSize [[point_size]];
};

// Vertex shader
vertex VertexOut pointCloudVertexShader(
    const device packed_float3* vertices [[buffer(0)]],
    const device packed_float3* colors [[buffer(1)]],
    constant Uniforms& uniforms [[buffer(2)]],
    uint vid [[vertex_id]]
) {
    VertexOut out;

    float4 position = float4(vertices[vid], 1.0);
    out.position = uniforms.modelViewProjectionMatrix * position;
    out.color = float3(colors[vid]);
    out.pointSize = 3.0; // Point size in pixels

    return out;
}

// Fragment shader
fragment float4 pointCloudFragmentShader(VertexOut in [[stage_in]]) {
    return float4(in.color, 1.0);
}
