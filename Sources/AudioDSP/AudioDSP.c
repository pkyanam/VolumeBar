#include "AudioDSP.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

struct VBRenderState {
    _Atomic(float) targetGain;
    _Atomic(float) inputPeak;
    _Atomic(float) outputPeak;
    _Atomic(uint64_t) callbacks;
    _Atomic(uint64_t) invalidBuffers;
    _Atomic(uint64_t) signalBuffers;
    float currentGain;
    float rampStep;
    uint32_t channels;
};

VBRenderState *VBRenderCreate(float gain, double sampleRate, uint32_t channels) {
    if (sampleRate < 8000 || sampleRate > 384000 || channels < 1 || channels > 2) return NULL;
    VBRenderState *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    gain = isfinite(gain) ? fminf(1, fmaxf(0, gain)) : 1;
    atomic_init(&s->targetGain, gain);
    atomic_init(&s->inputPeak, 0);
    atomic_init(&s->outputPeak, 0);
    atomic_init(&s->callbacks, 0);
    atomic_init(&s->invalidBuffers, 0);
    atomic_init(&s->signalBuffers, 0);
    s->currentGain = gain;
    s->rampStep = 1.0f / (float)(sampleRate * 0.010); // 10 ms, no clicks.
    s->channels = channels;
    return s;
}
void VBRenderDestroy(VBRenderState *s) { free(s); }
void VBRenderSetGain(VBRenderState *s, float gain) {
    if (s) atomic_store_explicit(&s->targetGain, isfinite(gain) ? fminf(1, fmaxf(0, gain)) : 1, memory_order_relaxed);
}
VBRenderStats VBRenderGetStats(VBRenderState *s) {
    VBRenderStats stats = {0};
    if (!s) return stats;
    stats.callbacks = atomic_load_explicit(&s->callbacks, memory_order_relaxed);
    stats.invalidBuffers = atomic_load_explicit(&s->invalidBuffers, memory_order_relaxed);
    stats.inputPeak = atomic_load_explicit(&s->inputPeak, memory_order_relaxed);
    stats.outputPeak = atomic_load_explicit(&s->outputPeak, memory_order_relaxed);
    stats.signalBuffers = atomic_load_explicit(&s->signalBuffers, memory_order_relaxed);
    stats.gain = atomic_load_explicit(&s->targetGain, memory_order_relaxed);
    return stats;
}

// HAL invokes this directly. No locks, allocation, logging, Swift, or file I/O here.
OSStatus VBRenderCallback(AudioObjectID device, const AudioTimeStamp *now,
                         const AudioBufferList *input, const AudioTimeStamp *inputTime,
                         AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    VBRenderState *s = context;
    if (!s || !output) return noErr;
    for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
        if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
    }
    atomic_fetch_add_explicit(&s->callbacks, 1, memory_order_relaxed);
    // Input is tap-only (physical input channels explicitly disabled). Support planar or interleaved Float32.
    bool valid = input && input->mNumberBuffers > 0 && input->mNumberBuffers <= 2 &&
                 output->mNumberBuffers > 0 && output->mNumberBuffers <= 2;
    uint32_t inChannels = 0, outChannels = 0, frames = UINT32_MAX;
    if (valid) {
        for (UInt32 b = 0; b < input->mNumberBuffers; b++) {
            const AudioBuffer *buf = &input->mBuffers[b];
            if (!buf->mData || !buf->mNumberChannels || buf->mNumberChannels > 2 ||
                buf->mDataByteSize % (sizeof(float) * buf->mNumberChannels)) { valid = false; break; }
            uint32_t n = buf->mDataByteSize / (sizeof(float) * buf->mNumberChannels);
            frames = frames < n ? frames : n;
            inChannels += buf->mNumberChannels;
        }
        for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
            const AudioBuffer *buf = &output->mBuffers[b];
            if (!buf->mData || !buf->mNumberChannels || buf->mNumberChannels > 2 ||
                buf->mDataByteSize % (sizeof(float) * buf->mNumberChannels)) { valid = false; break; }
            uint32_t n = buf->mDataByteSize / (sizeof(float) * buf->mNumberChannels);
            frames = frames < n ? frames : n;
            outChannels += buf->mNumberChannels;
        }
    }
    if (!valid || inChannels != s->channels || outChannels != s->channels || frames == UINT32_MAX) {
        atomic_fetch_add_explicit(&s->invalidBuffers, 1, memory_order_relaxed);
        return noErr;
    }
    float peakIn = 0, peakOut = 0;
    float gain = s->currentGain;
    const float target = atomic_load_explicit(&s->targetGain, memory_order_relaxed);
    for (uint32_t f = 0; f < frames; f++) {
        gain += fmaxf(-s->rampStep, fminf(s->rampStep, target - gain));
        for (uint32_t c = 0; c < s->channels; c++) {
            const AudioBuffer *ib = &input->mBuffers[input->mNumberBuffers == 1 ? 0 : c];
            AudioBuffer *ob = &output->mBuffers[output->mNumberBuffers == 1 ? 0 : c];
            float sample = ((const float *)ib->mData)[f * ib->mNumberChannels + (ib->mNumberChannels == 1 ? 0 : c)];
            if (!isfinite(sample)) sample = 0;
            float scaled = fmaxf(-1, fminf(1, sample * gain));
            ((float *)ob->mData)[f * ob->mNumberChannels + (ob->mNumberChannels == 1 ? 0 : c)] = scaled;
            peakIn = fmaxf(peakIn, fabsf(sample));
            peakOut = fmaxf(peakOut, fabsf(scaled));
        }
    }
    s->currentGain = gain;
    if (peakIn > 0.00000001f) atomic_fetch_add_explicit(&s->signalBuffers, 1, memory_order_relaxed);
    atomic_store_explicit(&s->inputPeak, peakIn, memory_order_relaxed);
    atomic_store_explicit(&s->outputPeak, peakOut, memory_order_relaxed);
    return noErr;
}
