#ifndef VOLUMEBAR_DSP_H
#define VOLUMEBAR_DSP_H
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct VBRenderState VBRenderState;
typedef struct {
    uint64_t callbacks;
    uint64_t invalidBuffers;
    uint64_t signalBuffers;
    float inputPeak;
    float outputPeak;
    float gain;
} VBRenderStats;
VBRenderState * _Nullable VBRenderCreate(float initialGain, double sampleRate, uint32_t channels);
void VBRenderDestroy(VBRenderState * _Nullable state);
void VBRenderSetGain(VBRenderState * _Nullable state, float gain);
VBRenderStats VBRenderGetStats(VBRenderState * _Nullable state);
OSStatus VBRenderCallback(AudioObjectID device, const AudioTimeStamp * _Nonnull now,
                         const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime,
                         AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime, void * _Nullable context);
#endif
