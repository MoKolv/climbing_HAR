//
//  ParticleTypes.h
//  arvos
//
//  Shared types for particle accumulation
//

#ifndef ParticleTypes_h
#define ParticleTypes_h

#include <simd/simd.h>

// Accumulated particle data
struct Particle {
    simd_float3 position;
    simd_float3 color;
    float confidence;
};

#endif /* ParticleTypes_h */
