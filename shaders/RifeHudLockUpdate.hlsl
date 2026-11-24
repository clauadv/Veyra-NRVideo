// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 DosukaSOL and the PushFPS contributors (https://github.com/DosukaSOL/PushFPS).
// Ported into Veyra on 2026-11-19 from PushFPS shaders/PushHudLockUpdate.hlsl (commit 3be641ca) and adapted: renamed and wired
// into Veyra's settings, engine and interface.
// RIFE HUD Lock, step 1 (pipeline/RifeHudLock.h): per pixel, how long it has stayed the
// same (x, 0..1) and how much contrast it has with its neighbours (y, a held maximum that fades).
Texture2D<float4> currentTex : register(t0);
Texture2D<float4> previousTex : register(t1);
RWTexture2D<float2> stateTex : register(u0);
RWTexture2D<uint> textMask : register(u1);
cbuffer Constants : register(b0) {
    uint width, height, reset, outputMode; // 0 sRGB, 1 scRGB (linear), 2 PQ
    uint fastText, transitions, pad2, pad3;
};
// A roughly perceptual value: sRGB and PQ are already encoded; scRGB is linear (1 = 80 nits).
float3 perceptual(float3 v) { return outputMode == 1 ? sqrt(max(v, 0) / 2.5) : v; }
float luma(float3 v) { return dot(v, float3(0.2126, 0.7152, 0.0722)); }
float3 at(int2 p) { return perceptual(currentTex[clamp(p, int2(0, 0), int2(width - 1, height - 1))].rgb); }

// 1/0.06: about 38 frames (1.3 s at 30 FPS) to reach 0.9 from zero.
static const float kRise = 0.06;
static const float kStill = 0.02;   // largest channel change still counted as the same pixel
static const float kFade = 0.97;    // held contrast fades about 3 % per frame

// SDR RIFE text protection across the picture. Neutral strokes with
// contrasting pixels on BOTH sides qualify, including dark text on light UI.
// Multiple stroke widths cover normal and bold menu fonts. Real-frame agreement prevents
// anticipating new captions or holding moving strokes. The three-pixel expansion
// includes antialiasing/outline without freezing a rectangular subtitle band.
// This is a visual heuristic, enabled by the graph for SDR RIFE HUD Lock.
float3 shapeAt(int2 p,bool newer){
    p=clamp(p,int2(0,0),int2(width-1,height-1));
    return newer?at(p):perceptual(previousTex[p].rgb);
}
bool subtitleBand(int2 p){return p.y>=int(height*82/100)&&p.y<int(height*97/100)&&p.x>=int(width*15/100)&&p.x<int(width*85/100);}
bool thinShape(int2 p,bool newer,bool neutral) {
    const float3 c = shapeAt(p,newer);
    const float lo=min(c.r,min(c.g,c.b)), hi=max(c.r,max(c.g,c.b));
    const float lum=luma(c);
    const bool light=neutral?lo>0.55:lum>0.55, dark=neutral?hi<0.25:lum<0.25;
    if ((!light&&!dark)||(neutral&&hi-lo>0.12)) return false;
    [unroll] for(uint scale=0;scale<3;++scale){
        const int radius=max(1,int((height*(2+scale*2)+540)/1080));
        const float left=luma(shapeAt(p-int2(radius,0),newer)),right=luma(shapeAt(p+int2(radius,0),newer));
        const float top=luma(shapeAt(p-int2(0,radius),newer)),bottom=luma(shapeAt(p+int2(0,radius),newer));
        if(light&&((left<0.25&&right<0.25)||(top<0.25&&bottom<0.25)))return true;
        if(dark&&((left>0.65&&right>0.65)||(top>0.65&&bottom>0.65)))return true;
    }
    return false;
}
uint classify(int2 p){
    const bool newerShape=thinShape(p,true,true);
    const float3 d=abs(at(p)-shapeAt(p,false));
    uint value=newerShape&&max(d.r,max(d.g,d.b))<.04?1:0;
    // Only the subtitle band permits unconfirmed text to acquire immediately.
    // Elsewhere retain the proven two-real-frame agreement behavior.
    if(transitions!=0&&subtitleBand(p)){
        const float3 a=shapeAt(p,false),b=at(p);
        // New unconfirmed captions need a bright neutral seed. This tighter
        // gate avoids snapping ordinary dark floor/scene texture on onset.
        const bool seedB=min(b.r,min(b.g,b.b))>.8||(luma(b)>.55&&max(b.r,max(b.g,b.b))-min(b.r,min(b.g,b.b))>.15);
        const bool seedA=min(a.r,min(a.g,a.b))>.8||(luma(a)>.55&&max(a.r,max(a.g,a.b))-min(a.r,min(a.g,a.b))>.15);
        if(seedB&&thinShape(p,true,false))value|=2;
        if(seedA&&thinShape(p,false,false))value|=4;
        if((value&6)!=0&&max(d.r,max(d.g,d.b))>.04)value|=8;
    }
    return value;
}

// Evaluate the shape once per tile pixel, then expand from shared memory.
// Re-running the shape test for all 25 neighbours was too expensive when the
// search was extended from the subtitle band to the whole picture.
groupshared uint strokes[676]; // 16x16 output tile + five-pixel transition halo
[numthreads(16, 16, 1)]
void main(uint3 id : SV_DispatchThreadID,uint3 local : SV_GroupThreadID,uint3 group : SV_GroupID) {
    bool stroke=false;
    uint textUnion=0;
    if(fastText!=0&&outputMode==0&&reset==0){
        for(uint index=local.y*16+local.x;index<676;index+=256){
            const int2 q=int2(group.xy*16)+int2(index%26,index/26)-5;
            strokes[index]=all(q>=0)&&q.x<int(width)&&q.y<int(height)?classify(q):0;
        }
        GroupMemoryBarrierWithGroupSync();
        [unroll] for(uint y=0;y<7;++y)
            [unroll] for(uint x=0;x<7;++x)
            {
                const uint flags=strokes[(local.y+y+2)*26+local.x+x+2];
                stroke=stroke||((flags&1)!=0);
            }
        if(transitions!=0&&subtitleBand(int2(id.xy))){
            [unroll] for(uint y=0;y<11;++y)[unroll] for(uint x=0;x<11;++x)
                textUnion|=strokes[(local.y+y)*26+local.x+x]&14;
        }
    }
    if (id.x >= width || id.y >= height) return;
    if(transitions!=0)textMask[id.xy]=reset==0&&subtitleBand(int2(id.xy))&&(textUnion&6)!=0?1|((textUnion&8)!=0?2:0):0;
    if (reset != 0) { stateTex[id.xy] = float2(0, 0); return; }
    const int2 p = int2(id.xy);
    const float3 c = at(p);
    const float3 d = abs(c - perceptual(previousTex[id.xy].rgb));
    const float change = max(d.r, max(d.g, d.b));
    const float l = luma(c);
    const float contrast = max(max(abs(l - luma(at(p + int2(1, 0)))), abs(l - luma(at(p - int2(1, 0))))),
                               max(abs(l - luma(at(p + int2(0, 1)))), abs(l - luma(at(p - int2(0, 1))))));
    float2 s = stateTex[id.xy];
    s.x = change < kStill ? s.x + (1 - s.x) * kRise : 0;
    s.y = change < kStill ? max(contrast, s.y * kFade) : contrast;
    if (stroke && change < 0.04) { s.x = 1; s.y = max(s.y,0.2); }
    stateTex[id.xy] = s;
}
