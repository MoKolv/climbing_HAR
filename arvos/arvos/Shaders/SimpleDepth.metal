//
//  SimpleDepth.metal
//  arvos
//
//  Simple test shader to verify Metal rendering works
//

#include <metal_stdlib>
using namespace metal;

struct SimpleVertex {
    float4 position;
    float4 color;
};

struct SimpleVertexOut {
    float4 position [[position]];
    float4 color;
    float pointSize [[point_size]];
};

vertex SimpleVertexOut simpleDepthVertex(const device SimpleVertex* vertices [[buffer(0)]],
                                          uint vid [[vertex_id]]) {
    SimpleVertexOut out;
    out.position = vertices[vid].position;
    out.color = vertices[vid].color;
    out.pointSize = 50.0; // Large points to see easily
    return out;
}

fragment float4 simpleDepthFragment(SimpleVertexOut in [[stage_in]]) {
    return in.color;
}
