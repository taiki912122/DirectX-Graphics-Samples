//*********************************************************
//
// Copyright (c) Microsoft. All rights reserved.
// This code is licensed under the MIT License (MIT).
// THIS CODE IS PROVIDED *AS IS* WITHOUT WARRANTY OF
// ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY
// IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR
// PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT.
//
//*********************************************************

#define HLSL
#include "RaytracingHlslCompat.h"

ConstantBuffer<ReduceSumCSCB> gCB: register(b0);
Texture2D<uint> g_texInput : register(t0);
RWTexture2D<uint> g_texOutput : register(u1);


// ToDo - dxc fails on
//groupshared uint gShared[ReduceSumCS::ThreadGroup::Width*ReduceSumCS::ThreadGroup::Height];
groupshared uint gShared[ReduceSumCS::ThreadGroup::Size];

// ReduceSumCS performance
// Ref: http://on-demand.gputechconf.com/gtc/2010/presentations/S12312-DirectCompute-Pre-Conference-Tutorial.pdf
//  N [uint] element loads per thread - 1080p | 4K gpu time: 
//		N = 1:   44   | 114.5 us
//		N = 4:   23.2 | 70 us
//		N = 8:   23.5 | 42 us
//		N = 10:  23	  | 42 us
//  Bandwidth: 361 | 790 GB/s.
//  GPU: RTX 2080 Ti
//  ThreadGroup: [8, 16]
[numthreads(ReduceSumCS::ThreadGroup::Width, ReduceSumCS::ThreadGroup::Height, 1)]
void main(
	uint3 DTid : SV_DispatchThreadID, 
	uint3 GTid : SV_GroupThreadID,
	uint GIndex: SV_GroupIndex,
	uint2 Gid : SV_GroupID)
{
	uint ThreadGroupSize = ReduceSumCS::ThreadGroup::Size;

	// Load the input data
	uint2 index = DTid.xy + uint2(Gid.x * ((ReduceSumCS::ThreadGroup::NumElementsToLoadPerThread - 1) * ReduceSumCS::ThreadGroup::Width), 0);
	UINT i = 0;
	uint sum = 0;
	while (i++ < ReduceSumCS::ThreadGroup::NumElementsToLoadPerThread)
	{
		sum += g_texInput[index].x;
		index += uint2(ReduceSumCS::ThreadGroup::Width, 0);
	}

	// Aggregate values across the wave.
	sum = WaveActiveSum(sum);

	for (UINT s = WaveGetLaneCount(); s < ThreadGroupSize; s*= WaveGetLaneCount())
	{
		// Store in shared memory and wait for all threads in group to finish.
		gShared[GIndex] = sum;		// ToDo test conditional write if (WaveIsFirstLane())
		GroupMemoryBarrierWithGroupSync();

		uint numLanesToProcess = (ThreadGroupSize + s - 1) / s;
		if (GIndex >= numLanesToProcess)
		{
			break;
		}
		// Load and aggregate values across the wave.
		sum = gShared[GIndex * WaveGetLaneCount()];
		sum = WaveActiveSum(sum);
	}

	// Write out summed result for each thread group.
	if (GIndex == 0)
	{
		g_texOutput[Gid] = sum;
	}
}