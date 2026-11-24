// SPDX-License-Identifier: GPL-3.0-only
// RIFE (RifeDmlBackend) input: the enhanced colour frame -> planar float RGB in
// [0, 1], NCHW, padded to the model size by repeating the last row/column.
// mode 1 fills one plane with a constant instead (the timestep input).

cbuffer Constants : register(b0)
{
    uint width;        // colour frame
    uint height;
    uint paddedWidth;  // model tensor
    uint paddedHeight;
    uint mode;         // 0 colour -> planes, 1 fill
    float value;       // mode 1
    uint planeCount;   // mode 1
    uint pad0;
};

Texture2D<float4> color : register(t0);
SamplerState linearClamp : register(s1);
RWByteAddressBuffer planes : register(u0);

[numthreads(16, 16, 1)]
void main(uint3 id : SV_DispatchThreadID)
{
    if (id.x >= paddedWidth || id.y >= paddedHeight) return;
    const uint plane = paddedWidth * paddedHeight;
    const uint index = id.y * paddedWidth + id.x;
    if (mode == 1) {
        for (uint c = 0; c < planeCount; ++c) planes.Store((c * plane + index) * 4, asuint(value));
        return;
    }
    // In colour mode planeCount/pad0 carry the active inference extent.
    float3 rgb;
    if(planeCount==width&&pad0==height)
        rgb=color.Load(int3(min(id.x,width-1),min(id.y,height-1),0)).rgb;
    else{
        float2 source=(float2(min(id.x,planeCount-1),min(id.y,pad0-1))+.5)/float2(planeCount,pad0);
        rgb=color.SampleLevel(linearClamp,source,0).rgb;
    }
    rgb=saturate(rgb);
    planes.Store((0 * plane + index) * 4, asuint(rgb.r));
    planes.Store((1 * plane + index) * 4, asuint(rgb.g));
    planes.Store((2 * plane + index) * 4, asuint(rgb.b));
}
