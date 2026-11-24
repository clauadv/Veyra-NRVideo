// SPDX-License-Identifier: GPL-3.0-only
// Small closed HUD frames and anchored colored meters. Geometry is detected
// from real A/B pixels without game coordinates or game-specific colors.
Texture2D<float4> currentTex : register(t0);
Texture2D<float4> previousTex : register(t1);
Texture2D<uint> textMask : register(t2);
RWTexture2D<uint4> boxes : register(u0);
cbuffer Constants : register(b0) {
    uint width,height,reset,outputMode;
    uint cellSize,maskWidth,maskHeight,pad;
};
float3 at(int2 p,bool newer){
    p=clamp(p,int2(0,0),int2(width-1,height-1));
    return newer?currentTex[p].rgb:previousTex[p].rgb;
}
float distanceRgb(float3 a,float3 b){float3 d=abs(a-b);return max(d.r,max(d.g,d.b));}
bool sameRailColor(float3 a,float3 b){
    const float x=max(a.r,max(a.g,a.b)),y=max(b.r,max(b.g,b.b));
    // Chroma subsampling and antialiasing mix a one-pixel rail with different
    // image/background colors on each side. Keep a color-family gate while
    // retaining the four-side geometry and strong thin-rail contrast checks.
    return min(x,y)>.55*max(x,y)&&distanceRgb(a/max(x,.001),b/max(y,.001))<.23;
}
int rail(int2 p,int2 direction,int2 along,int radius,bool newer){
    const int span=max(2,int(height*4/1080));
    int first=0,best=0;float3 reference=0;
    [loop] for(int i=1;i<=radius;++i){
        if(first!=0&&i>first+max(3,int(height*12/1080)))break;
        const int2 q=p+direction*i;
        if(any(q-along*span*2<0)||any(q+along*span*2>=int2(width,height))||any(q<2)||any(q>=int2(width,height)-2))continue;
        const float3 c=at(q,newer);
        const float hi=max(c.r,max(c.g,c.b)),lo=min(c.r,min(c.g,c.b));
        if(hi<0.35||(hi-lo<0.15&&dot(c,float3(.2126,.7152,.0722))<.65))continue;
        if(distanceRgb(c,at(q+along*span,newer))>.045||distanceRgb(c,at(q-along*span,newer))>.045||
           distanceRgb(c,at(q+along*span*2,newer))>.045||distanceRgb(c,at(q-along*span*2,newer))>.045)continue;
        const float outer=distanceRgb(c,at(q+direction*2,newer)),inner=distanceRgb(c,at(q-direction*2,newer));
        if(min(outer,inner)<.045||max(outer,inner)<.12)continue;
        // The first candidate can be the image-side antialiased edge. Prefer
        // the outer matching rail within a bounded image-edge inset,
        // then validate the complete rectangle rather than a photo feature.
        if(first==0){first=i;best=i;reference=c;}
        else if(sameRailColor(reference,c))best=i;
    }
    return best;
}
uint4 findBox(int2 p,bool newer){
    const int radius=max(16,int(height*80/1080));
    const int l=rail(p,int2(-1,0),int2(0,1),radius,newer);
    if(l==0)return 0;
    const int r=rail(p,int2(1,0),int2(0,1),radius,newer);
    if(r==0)return 0;
    const int t=rail(p,int2(0,-1),int2(1,0),radius,newer);
    if(t==0)return 0;
    const int b=rail(p,int2(0,1),int2(1,0),radius,newer);
    if(b==0)return 0;
    const int w=l+r,h=t+b,minSize=max(16,int(height*28/1080)),maxSize=max(32,int(height*96/1080));
    if(min(w,h)<minSize||max(w,h)>maxSize||float(w)/h<.7||float(w)/h>1.4)return 0;
    const int2 lo=p-int2(l,t),hi=p+int2(r,b);
    const float3 color=at(int2(lo.x,p.y),newer);
    if(!sameRailColor(color,at(int2(hi.x,p.y),newer))||!sameRailColor(color,at(int2(p.x,lo.y),newer))||!sameRailColor(color,at(int2(p.x,hi.y),newer)))return 0;
    // Reject unrelated crossing lines: each entire side has two extra samples.
    [unroll] for(int quarter=1;quarter<=3;quarter+=2){
        const int x=lo.x+w*quarter/4,y=lo.y+h*quarter/4;
        if(!sameRailColor(color,at(int2(lo.x,y),newer))||!sameRailColor(color,at(int2(hi.x,y),newer))||
           !sameRailColor(color,at(int2(x,lo.y),newer))||!sameRailColor(color,at(int2(x,hi.y),newer)))return 0;
    }
    return uint4(max(lo-1,0),min(hi+2,int2(width,height)));
}
int meterEnd(int2 p,int2 direction,int limit,uint gapLimit,bool newer){
    const float3 color=at(p,newer);uint gaps=0;
    [loop] for(int distance=1;distance<=limit;++distance){
        const int2 q=p+direction*distance;
        if(any(q<0)||any(q>=int2(width,height)))return distance;
        gaps=distanceRgb(color,at(q,newer))>.12?gaps+1:0;
        if(gaps>=gapLimit)return distance-int(gapLimit)+1;
    }
    return 0;
}
uint4 findMeter(int2 p,bool newer){
    if(any(p<0)||any(p>=int2(width,height)))return 0;
    const float3 color=at(p,newer);
    if(max(color.r,max(color.g,color.b))-min(color.r,min(color.g,color.b))<.18||dot(color,float3(.2126,.7152,.0722))<.32)return 0;
    const int vertical=max(2,int(height*12/1080));
    if(distanceRgb(color,at(p-int2(0,vertical),newer))<.12||distanceRgb(color,at(p+int2(0,vertical),newer))<.12)return 0;
    // Reject isolated colored pixels before bounded endpoint walks.
    const int support=max(4,int(height*24/1080));
    if(distanceRgb(color,at(p-int2(support,0),newer))>.08&&distanceRgb(color,at(p+int2(support,0),newer))>.08)return 0;
    const int radius=max(64,int(height*512/1080));
    const uint gap=max(2,uint(height*5/1080));
    const int l=meterEnd(p,int2(-1,0),radius,gap,newer),r=meterEnd(p,int2(1,0),radius,gap,newer);
    if(l==0||r==0)return 0;
    const int t=meterEnd(p,int2(0,-1),vertical*2,1,newer),b=meterEnd(p,int2(0,1),vertical*2,1,newer);
    const int w=l+r-1,h=t+b-1;
    if(t==0||b==0||w<max(32,int(height*80/1080))||w>radius||h<max(2,int(height*4/1080))||h>vertical*2||w<h*6)return 0;
    const int2 lo=p-int2(l-1,t-1),hi=p+int2(r,b);
    uint matching=0;
    [unroll] for(int step=1;step<=7;++step){
        const int x=lo.x+w*step/8;
        matching+=distanceRgb(color,at(int2(x,p.y),newer))<.08?1:0;
        // A complete thin strip has contrast on both long outside edges.
        if(distanceRgb(color,at(int2(x,lo.y-2),newer))<.10||distanceRgb(color,at(int2(x,hi.y+1),newer))<.10)return 0;
    }
    if(matching<5)return 0;
    return uint4(max(lo,0),min(hi,int2(width,height)));
}
uint4 anchoredMeter(int2 p){
    const uint4 box=findMeter(p,true);
    if(box.z==0)return 0;
    // Reuse the validated colored seed: a strip's center can be a black tick.
    const uint4 old=findMeter(p,false);
    if(old.z==0||distanceRgb(at(p,true),at(p,false))>.06)return 0;
    const int4 movement=abs(int4(box)-int4(old));
    if(movement.x>2||movement.z>2||movement.y>1||movement.w>1)return 0;
    // Tag a meter core. D3D12 texture coordinates fit below bit15. Compose
    // checks a bounded exterior margin for leaked meter color; copying an
    // entire background rectangle here would produce a visible moving seam.
    return uint4(box.x|0x8000u,box.yzw);
}
[numthreads(8,8,1)]
void main(uint3 id:SV_DispatchThreadID){
    if(id.x>=maskWidth||id.y>=maskHeight)return;
    if(reset!=0||outputMode!=0){boxes[id.xy]=0;return;}
    // Changed caption glyphs acquire as coherent local patches, so interpolation
    // fragments outside the exact source strokes cannot leak through on onset.
    // Stable captions retain the narrow pixel mask rather than a held band.
    int2 low=int2(width,height),high=0;bool changed=false;
    [loop] for(uint y=0;y<cellSize;++y)[loop] for(uint x=0;x<cellSize;++x){
        const int2 q=int2(id.xy*cellSize+uint2(x,y));
        if(any(q>=int2(width,height)))continue;
        const uint value=textMask[q];
        if((value&1)!=0){low=min(low,q);high=max(high,q+1);}
        changed=changed||((value&2)!=0);
    }
    if(changed&&all(high>low)){
        boxes[id.xy]=uint4(max(low-8,int2(width*15/100,height*82/100)),min(high+8,int2(width*85/100,height*97/100)));
        return;
    }
    const int2 p=min(int2(id.xy*cellSize+cellSize/2),int2(width,height)-1);
    uint4 meter=anchoredMeter(p);
    // Two additional vertical probes cover thin strips between 16px centers.
    if(meter.z==0)meter=anchoredMeter(p-int2(0,cellSize/4));
    if(meter.z==0)meter=anchoredMeter(p+int2(0,cellSize/4));
    if(meter.z!=0){boxes[id.xy]=meter;return;}
    uint4 box=findBox(p,true),old=0;
    if(box.z!=0)old=findBox(int2((box.xy+box.zw)/2),false);
    else{
        old=findBox(p,false);
        if(old.z!=0)box=findBox(int2((old.xy+old.zw)/2),true);
    }
    // A framed object moving through the scene is not an anchored HUD island.
    if(box.z!=0&&old.z!=0&&any(abs(int4(box)-int4(old))>1))box=0;
    else if(box.z==0)box=old;
    boxes[id.xy]=box;
}
