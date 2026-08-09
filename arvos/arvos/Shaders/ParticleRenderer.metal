//
//  ParticleRenderer.metal
//  arvos
//
//  Renders accumulated particles from buffer
//

#include <metal_stdlib>
#include "ParticleTypes.h"
using namespace metal;

struct RenderUniforms {
    float4x4 viewProjectionMatrix;
    float pointSize;
    int confidenceThreshold;
};

struct ParticleVertexOut {
    float4 position [[position]];
    float4 color;
    float pointSize [[point_size]];
};

/// Vertex shader for rendering particles
vertex ParticleVertexOut particleVertex(uint vertexID [[vertex_id]],
                                          constant RenderUniforms &uniforms [[buffer(0)]],
                                          const device Particle *particles [[buffer(1)]]) {

    ParticleVertexOut out;

    const Particle particle = particles[vertexID];

    // Filter by confidence
    if (int(particle.confidence) < uniforms.confidenceThreshold) {
        out.position = float4(0, 0, -1000, 1);
        out.color = float4(0);
        out.pointSize = 0;
        return out;
    }

    // Transform to clip space
    out.position = uniforms.viewProjectionMatrix * float4(particle.position, 1.0);
    out.color = float4(particle.color, 1.0);
    out.pointSize = uniforms.pointSize;

    return out;
}

/// Fragment shader for particles
fragment float4 particleFragment(ParticleVertexOut in [[stage_in]],
                                  float2 pointCoord [[point_coord]]) {

    // Create circular particles
    float2 center = pointCoord - float2(0.5);
    float dist = length(center);

    // Smooth circle edge
    float alpha = 1.0 - smoothstep(0.4, 0.5, dist);

    if (alpha < 0.01) {
        discard_fragment();
    }

    return float4(in.color.rgb, alpha);
}
