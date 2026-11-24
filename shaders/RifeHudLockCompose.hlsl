// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 DosukaSOL and the PushFPS contributors (https://github.com/DosukaSOL/PushFPS).
// Ported into Veyra on 2026-11-19 from PushFPS shaders/PushHudLockCompose.hlsl (commit 3be641ca) and adapted: renamed and wired
// into Veyra's settings, engine and interface.
// RIFE HUD Lock, step 2 (pipeline/RifeHudLock.h): a generated frame takes its locked
// pixels from the held real frame. A pixel is locked when it has been still for about a second
// itself and it, or a neighbour that is just as still, has an edge: the inside of a thin stroke
// and the pixel beside an edge belong to the overlay too. A pixel that moves is never locked.
Texture2D<float4> generatedTex : register(t0);
Texture2D<float4> heldTex : register(t1);
Texture2D<float2> stateTex : register(t2);
Texture2D<float> dynamicMask : register(t3);
Texture2D<float4> newerTex : register(t4);
Texture2D<uint> textMask : register(t5);
Texture2D<uint4> regionBoxes : register(t6);
RWTexture2D<float4> outputTex : register(u0);
cbuffer Constants : register(b0) {
    uint width, height, outputMode, lockStatic;
    uint dynamicCell, useNewer, transitions, regionCell;
};
float stillOf(float2 s) { return smoothstep(0.80, 0.95, s.x); }
float edgeOf(float2 s) {
    const float edge = outputMode == 1 ? 0.03 : 0.04;
    return smoothstep(edge, edge * 2.5, s.y);
}
groupshared uint regionLeft,regionTop,regionRight,regionBottom;
groupshared uint meterLeft,meterTop,meterRight,meterBottom;
[numthreads(16, 16, 1)]
void main(uint3 id : SV_DispatchThreadID,uint3 local : SV_GroupThreadID,uint3 group : SV_GroupID) {
    if(transitions!=0&&lockStatic!=0){
        const uint thread=local.y*16+local.x;
        if(thread==0){regionLeft=width;regionTop=height;regionRight=0;regionBottom=0;meterLeft=width;meterTop=height;meterRight=0;meterBottom=0;}
        GroupMemoryBarrierWithGroupSync();
        // A complete <=96px region may have only one reliable detection tile.
        // Gather nearby candidates once per workgroup, clip their union to our
        // 16px tile, then apply that shared coverage to every output pixel.
        if(thread<169){
            const int2 cell=int2(group.xy),limits=int2((width+regionCell-1)/regionCell,(height+regionCell-1)/regionCell);
            const int2 q=cell+int2(thread%13,thread/13)-6;
            if(all(q>=0)&&all(q<limits)){
                uint4 box=regionBoxes[q];
                const uint2 origin=group.xy*regionCell;
                if((box.x&0x8000u)!=0){
                    box.x&=0x7fffu;
                    const int2 margin=int2(max(4,int(height*20/1080)),max(2,int(height*5/1080)));
                    const uint2 expandedLo=uint2(max(int2(box.xy)-margin,0)),expandedHi=uint2(min(int2(box.zw)+margin,int2(width,height)));
                    if(all(min(expandedHi,origin+regionCell)>max(expandedLo,origin))){
                        InterlockedMin(meterLeft,box.x);InterlockedMin(meterTop,box.y);
                        InterlockedMax(meterRight,box.z);InterlockedMax(meterBottom,box.w);
                    }
                }else{
                    const uint2 lo=max(box.xy,origin),hi=min(box.zw,min(origin+regionCell,uint2(width,height)));
                    if(all(hi>lo)){
                        InterlockedMin(regionLeft,lo.x);InterlockedMin(regionTop,lo.y);
                        InterlockedMax(regionRight,hi.x);InterlockedMax(regionBottom,hi.y);
                    }
                }
            }
        }
        GroupMemoryBarrierWithGroupSync();
    }
    if (id.x >= width || id.y >= height) return;
    const float4 g = generatedTex[id.xy];
    if(transitions!=0&&lockStatic!=0){
        bool protectedPixel=textMask[id.xy]!=0;
        protectedPixel=protectedPixel||(regionRight>regionLeft&&regionBottom>regionTop&&
            all(id.xy>=uint2(regionLeft,regionTop))&&all(id.xy<uint2(regionRight,regionBottom)));
        if(protectedPixel){
            outputTex[id.xy]=float4(useNewer!=0?newerTex[id.xy].rgb:heldTex[id.xy].rgb,g.a);
            return;
        }
        if(meterRight>meterLeft&&meterBottom>meterTop){
            const int2 margin=int2(max(4,int(height*20/1080)),max(2,int(height*5/1080)));
            const int2 p=int2(id.xy),lo=int2(meterLeft,meterTop),hi=int2(meterRight,meterBottom);
            if(all(p>=lo-margin)&&all(p<hi+margin)){
                const int outline=max(1,int(height*3/1080));
                bool restore=all(p>=lo-outline)&&all(p<hi+outline);
                if(!restore){
                    int2 sample=int2(lo.x+(hi.x-lo.x)/4,(lo.y+hi.y)/2);
                    float3 reference=useNewer!=0?newerTex[sample].rgb:heldTex[sample].rgb;
                    if(max(reference.r,max(reference.g,reference.b))-min(reference.r,min(reference.g,reference.b))<.18){
                        sample.x=lo.x+(hi.x-lo.x)*3/4;
                        reference=useNewer!=0?newerTex[sample].rgb:heldTex[sample].rgb;
                    }
                    const float refPeak=max(reference.r,max(reference.g,reference.b));
                    // Erase leaked meter-colored tails, while retaining normal
                    // interpolated background in the rest of the margin. A
                    // two-pixel halo includes weak antialiased contamination
                    // around a strongly colored tail, avoiding a residual ring.
                    [unroll] for(int y=-2;y<=2;++y)[unroll] for(int x=-2;x<=2;++x){
                        const int2 q=clamp(p+int2(x,y),int2(0,0),int2(width,height)-1);
                        const float3 candidate=generatedTex[q].rgb;
                        const float peak=max(candidate.r,max(candidate.g,candidate.b));
                        const float3 hueDelta=abs(candidate/max(peak,.001)-reference/max(refPeak,.001));
                        const float3 a=heldTex[q].rgb,b=newerTex[q].rgb;
                        const float3 ah=abs(a/max(max(a.r,max(a.g,a.b)),.001)-reference/max(refPeak,.001));
                        const float3 bh=abs(b/max(max(b.r,max(b.g,b.b)),.001)-reference/max(refPeak,.001));
                        const float sourceHue=min(max(ah.r,max(ah.g,ah.b)),max(bh.r,max(bh.g,bh.b)));
                        const float3 da=abs(candidate-a),db=abs(candidate-b);
                        const float difference=min(max(da.r,max(da.g,da.b)),max(db.r,max(db.g,db.b)));
                        const float hue=max(hueDelta.r,max(hueDelta.g,hueDelta.b));
                        restore=restore||(peak>.25*refPeak&&peak-min(candidate.r,min(candidate.g,candidate.b))>.12&&hue<.25&&hue+.06<sourceHue&&difference>.06);
                    }
                }
                if(restore){
                    outputTex[id.xy]=float4(useNewer!=0?newerTex[id.xy].rgb:heldTex[id.xy].rgb,g.a);
                    return;
                }
            }
        }
    }
    if (dynamicCell != 0) {
        if (dynamicMask[id.xy / dynamicCell] > 0.5) {
            const float3 hud = useNewer != 0 ? newerTex[id.xy].rgb : heldTex[id.xy].rgb;
            outputTex[id.xy] = float4(hud, g.a);
            return;
        }
    }
    if (lockStatic == 0) {
        outputTex[id.xy] = g;
        return;
    }
    const float still = stillOf(stateTex[id.xy]);
    float edge = 0;
    if (still > 0) {
        [unroll] for (int y = -1; y <= 1; ++y)
            [unroll] for (int x = -1; x <= 1; ++x) {
                const float2 q = stateTex[clamp(int2(id.xy) + int2(x, y), int2(0, 0), int2(width - 1, height - 1))];
                edge = max(edge, edgeOf(q) * stillOf(q));
            }
    }
    const float w = still * edge;
    outputTex[id.xy] = w > 0 ? float4(lerp(g.rgb, heldTex[id.xy].rgb, w), g.a) : g;
}
