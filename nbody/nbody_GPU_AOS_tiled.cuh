/*
 *
 * nbody_GPU_AOS_tiled.cuh
 *
 * CUDA implementation of the O(N^2) N-body calculation.
 * Tiled to take advantage of the symmetry of gravitational
 * forces: Fij=-Fji
 *
 * Copyright (c) 2011-2012, Archaea Software, LLC.
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions 
 * are met: 
 *
 * 1. Redistributions of source code must retain the above copyright 
 *    notice, this list of conditions and the following disclaimer. 
 * 2. Redistributions in binary form must reproduce the above copyright 
 *    notice, this list of conditions and the following disclaimer in 
 *    the documentation and/or other materials provided with the 
 *    distribution. 
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS 
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT 
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS 
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE 
 * COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, 
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, 
 * BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER 
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT 
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN 
 * ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE 
 * POSSIBILITY OF SUCH DAMAGE.
 *
 */

template<int nTile>
__device__ void
DoDiagonalTile_GPU( 
    float *force, 
    float *posMass,
    float softeningSquared,
    size_t iTile, size_t jTile
)
{
    size_t i = iTile*nTile+threadIdx.x;
    float acc[3] = {0, 0, 0};
    float myX = posMass[i*4+0];
    float myY = posMass[i*4+1];
    float myZ = posMass[i*4+2];

    for ( size_t _j = 0; _j < nTile; _j++ ) {
        size_t j = jTile*nTile+_j;

        float fx, fy, fz;
        float bodyX = posMass[j*4+0];
        float bodyY = posMass[j*4+1];
        float bodyZ = posMass[j*4+2];
        float bodyMass = posMass[j*4+3];

        bodyBodyInteraction<float>(
            &fx, &fy, &fz,
            myX, myY, myZ,
            bodyX, bodyY, bodyZ, bodyMass,
            softeningSquared );
        acc[0] += fx;
        acc[1] += fy;
        acc[2] += fz;
    }

    atomicAdd( &force[3*i+0], acc[0] );
    atomicAdd( &force[3*i+1], acc[1] );
    atomicAdd( &force[3*i+2], acc[2] );
}

#if 1
template<typename ReductionType, typename T, unsigned int numThreads>
__device__ void
Reduction4_LogStepShared( volatile ReductionType *sPartials )
{
    const int tid = threadIdx.x;
    if (numThreads >= 1024) {
        if (tid < 512) { 
            sPartials[tid] += sPartials[tid + 512];
        }
        __syncthreads();
    }
    if (numThreads >= 512) { 
        if (tid < 256) {
            sPartials[tid] += sPartials[tid + 256]; 
        } 
        __syncthreads();
    }
    if (numThreads >= 256) {
        if (tid < 128) {
            sPartials[tid] += sPartials[tid + 128];
        } 
        __syncthreads();
    }
    if (numThreads >= 128) {
        if (tid <  64) { 
            sPartials[tid] += sPartials[tid +  64];
        } 
        __syncthreads();
    }

    // warp synchronous at the end
    if ( tid < 32 ) {
        volatile ReductionType *wsSum = sPartials;
        if (numThreads >=  64) { wsSum[tid] += wsSum[tid + 32]; }
        if (numThreads >=  32) { wsSum[tid] += wsSum[tid + 16]; }
        if (numThreads >=  16) { wsSum[tid] += wsSum[tid +  8]; }
        if (numThreads >=   8) { wsSum[tid] += wsSum[tid +  4]; }
        if (numThreads >=   4) { wsSum[tid] += wsSum[tid +  2]; }
        if (numThreads >=   2) { wsSum[tid] += wsSum[tid +  1]; }
    }
}
#else
inline float
__device__
warpReduce( float x )
{
    x += __int_as_float( __shfl_xor( __float_as_int(x), 16 ) );
    x += __int_as_float( __shfl_xor( __float_as_int(x),  8 ) );
    x += __int_as_float( __shfl_xor( __float_as_int(x),  4 ) );
    x += __int_as_float( __shfl_xor( __float_as_int(x),  2 ) );
    x += __int_as_float( __shfl_xor( __float_as_int(x),  1 ) );
    return x;
}
#endif

template<int numThreads>
inline void
__device__
warpReduce( volatile float wsSum[numThreads] )
{
    const int tid = threadIdx.x;
    if (numThreads >=  32) { wsSum[tid] += wsSum[tid + 16]; }
    if (numThreads >=  16) { wsSum[tid] += wsSum[tid +  8]; }
    if (numThreads >=   8) { wsSum[tid] += wsSum[tid +  4]; }
    if (numThreads >=   4) { wsSum[tid] += wsSum[tid +  2]; }
    if (numThreads >=   2) { wsSum[tid] += wsSum[tid +  1]; }
}

template<int nTile>
__device__ void
DoNondiagonalTile_GPU( 
    float *force, 
    float *posMass,
    float softeningSquared,
    size_t iTile, size_t jTile
)
{
    size_t i = iTile*nTile+threadIdx.x;
    float ax = 0.0f, ay = 0.0f, az = 0.0f;
    float myX = posMass[i*4+0];
    float myY = posMass[i*4+1];
    float myZ = posMass[i*4+2];

    volatile __shared__ float symmetricX[nTile];
    volatile __shared__ float symmetricY[nTile];
    volatile __shared__ float symmetricZ[nTile];

    for ( size_t _j = 0; _j < nTile; _j++ ) {
        size_t j = jTile*nTile+_j;

        float fx, fy, fz;
        float bodyX = posMass[j*4+0];
        float bodyY = posMass[j*4+1];
        float bodyZ = posMass[j*4+2];
        float bodyMass = posMass[j*4+3];

        bodyBodyInteraction<float>(
            &fx, &fy, &fz,
            myX, myY, myZ,
            bodyX, bodyY, bodyZ, bodyMass,
            softeningSquared );

        ax += fx;
        ay += fy;
        az += fz;

        symmetricX[threadIdx.x] = -fx;
        symmetricY[threadIdx.x] = -fy;
        symmetricZ[threadIdx.x] = -fz;

#if 0
        warpReduce<nTile>( symmetricX );
        warpReduce<nTile>( symmetricY );
        warpReduce<nTile>( symmetricZ );
#else
        Reduction4_LogStepShared<float,float,nTile>( symmetricX );
        Reduction4_LogStepShared<float,float,nTile>( symmetricY );
        Reduction4_LogStepShared<float,float,nTile>( symmetricZ );
#endif

#if 0
        fx = warpReduce( -fx );
        fy = warpReduce( -fy );
        fz = warpReduce( -fz );
#endif
        if ( threadIdx.x == 0 ) {
            atomicAdd( &force[3*j+0], symmetricX[0] );
            atomicAdd( &force[3*j+1], symmetricY[0] );
            atomicAdd( &force[3*j+2], symmetricZ[0]);
        }
    }

    atomicAdd( &force[3*i+0], ax );
    atomicAdd( &force[3*i+1], ay );
    atomicAdd( &force[3*i+2], az );

}


template<int nTile>
__global__ void
ComputeNBodyGravitation_GPU_diagonaltile( float *force, float *posMass, size_t N, float softeningSquared, int iTile, int jTile )
{
    DoDiagonalTile_GPU<32>( force, posMass, softeningSquared, iTile, jTile );
}

template<int nTile>
__global__ void
ComputeNBodyGravitation_GPU_nondiagonaltile( float *force, float *posMass, size_t N, float softeningSquared, int iTile, int jTile )
{
    DoNondiagonalTile_GPU<32>( force, posMass, softeningSquared, iTile, jTile );
}



#if 0
template<int nTile>
__global__ void
ComputeNBodyGravitation_GPU_tiled( float *force, float *posMass, size_t N, float softeningSquared )
{
    for ( int iTile = blockIdx.x*gridDim.x;
              iTile < N/nTile;
              iTile += gridDim.x )
    {
        for ( int jTile = 0;
                  jTile < N/nTile;
                  jTile += 1 )
        {
            DoDiagonalTile_GPU<32>( force, posMass, softeningSquared, iTile, jTile );
        }
    }
}
#endif

template<int nTile>
__global__ void
ComputeNBodyGravitation_GPU_tiled( float *force, float *posMass, size_t N, float softeningSquared )
{
    int iTile = blockIdx.x;
    int jTile = blockIdx.y;
    if ( iTile == jTile ) {
        DoDiagonalTile_GPU<nTile>( force, posMass, softeningSquared, iTile, jTile );
    }
    else if ( jTile < iTile ) {
        DoNondiagonalTile_GPU<nTile>( force, posMass, softeningSquared, iTile, jTile );
    }
}

cudaError_t
ComputeGravitation_GPU_AOS_tiled(
    float *force, 
    float *posMass,
    float softeningSquared,
    size_t N
)
{
    cudaError_t status;

    dim3 blocks( N/32, N/32, 1 );

    CUDART_CHECK( cudaMemset( force, 0, 3*N*sizeof(float) ) );
    ComputeNBodyGravitation_GPU_tiled<32><<<blocks,32>>>( force, posMass, N, softeningSquared );
    CUDART_CHECK( cudaDeviceSynchronize() );
Error:
    return status;
}
