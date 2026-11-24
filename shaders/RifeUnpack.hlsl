// SPDX-License-Identifier: GPL-3.0-only
// RIFE (RifeDmlBackend) output: planar float RGB (NCHW, padded) -> the
// generated colour frame, cropped to the working size, alpha 1.

cbuffer Constants : register(b0)
{
    uint width;
    uint height;
    uint paddedWidth;
    uint paddedHeight;
    uint inferWidth, inferHeight, pad2, pad3;
};

// The planes stay in UNORDERED_ACCESS: DirectML writes them in that state.
RWByteAddressBuffer planes : register(u0);
RWTexture2D<float4> output : register(u1);
float3 loadColor(int2 p){
    p=clamp(p,0,int2(inferWidth-1,inferHeight-1));uint n=paddedWidth*paddedHeight,i=p.y*paddedWidth+p.x;
    return float3(asfloat(planes.Load(i*4)),asfloat(planes.Load((n+i)*4)),asfloat(planes.Load((2*n+i)*4)));
}

[numthreads(16, 16, 1)]
void main(uint3 id : SV_DispatchThreadID)
{
    if (id.x >= width || id.y >= height) return;
    if(inferWidth!=width||inferHeight!=height){
        float2 q=(float2(id.xy)+.5)*float2(inferWidth,inferHeight)/float2(width,height)-.5;
        int2 p=int2(floor(q));float2 f=frac(q);
        float3 rgb=lerp(lerp(loadColor(p),loadColor(p+int2(1,0)),f.x),lerp(loadColor(p+int2(0,1)),loadColor(p+1),f.x),f.y);
        output[id.xy]=float4(saturate(rgb),1);return;
    }
    const uint plane = paddedWidth * paddedHeight;
    const uint index = id.y * paddedWidth + id.x;
    const float r = asfloat(planes.Load((0 * plane + index) * 4));
    const float g = asfloat(planes.Load((1 * plane + index) * 4));
    const float b = asfloat(planes.Load((2 * plane + index) * 4));
    output[id.xy] = float4(saturate(float3(r, g, b)), 1.0);
}
