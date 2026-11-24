// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 DosukaSOL and the PushFPS contributors (https://github.com/DosukaSOL/PushFPS).
// Ported into Veyra on 2026-11-19 from PushFPS include/veyra/pipeline/PushHudLock.h (commit 3be641ca) and adapted: renamed and wired
// into Veyra's settings, engine and interface.
#pragma once
// RIFE-specific HUD protection with its own GPU resources and shaders.
#include "veyra/pipeline/GpuPassUtils.h"
#include <algorithm>
#include <array>
#include <string>

namespace veyra::pipeline {

class RifeHudLock {
public:
    static constexpr UINT kConstants = 8;
    static constexpr UINT kMaxGenerated = 32;
    // outputMode: how the frames are encoded, as EffectExclusion (0 sRGB, 1 scRGB, 2 PQ).
    bool initialize(ID3D12Device* device, uint32_t width, uint32_t height, DXGI_FORMAT format,
                    unsigned outputMode, bool staticLock = true, bool dynamicProtection = false,
                    bool fastText = true, bool transitions = true);
    bool dynamicActive() const { return bool(protectionMask_); }
    // real[0..1]: the graph's two real-frame textures by parity; generated: the
    // generated-frame textures, in the graph's slot order.
    void createViews(ID3D12Device* device, DescriptorStager& stager, ID3D12Resource* const real[2],
                     ID3D12Resource* const* generated, unsigned generatedCount);
    // After real frame `parity` is final: learn from real[1-parity] -> real[parity].
    // reset: no valid previous frame (start, seek, settings change): start over.
    bool update(ID3D12GraphicsCommandList* list, StateTracker& tracker, unsigned parity, bool reset);
    // Locked pixels of generated[slot] come from the held real frame real[heldParity].
    bool compose(ID3D12GraphicsCommandList* list, StateTracker& tracker, unsigned slot, unsigned heldParity,
                 bool useNewerHud = false);
    std::string describe() const;

private:
    uint32_t width_ = 0, height_ = 0;
    uint32_t cellSize_ = 0, maskWidth_ = 0, maskHeight_ = 0;
    unsigned outputMode_ = 0, generatedCount_ = 0;
    bool staticLock_ = true;
    bool fastText_ = false;
    bool transitions_ = false;
    DXGI_FORMAT format_ = DXGI_FORMAT_UNKNOWN;
    ComputePass update_, dynamic_, fill_, compose_, regions_;
    ComPtr<ID3D12Resource> state_, dynamicMask_, protectionMask_, scratch_;
    ComPtr<ID3D12Resource> textMask_, regionBoxes_;
    ID3D12Resource* real_[2]{};
    ID3D12Resource* generated_[kMaxGenerated]{};
};
}
