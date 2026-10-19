#ifndef ARCTIS_AUDIO_RING_H
#define ARCTIS_AUDIO_RING_H
#include <stdint.h>
#include <stddef.h>
typedef struct ArctisRing ArctisRing;
ArctisRing *arctis_ring_create(uint32_t channels, uint32_t capacity);
void arctis_ring_destroy(ArctisRing *ring);
// Single producer / single consumer; no allocation or locks on audio threads.
void arctis_ring_write(ArctisRing *ring, const float *samples, uint32_t frames);
void arctis_ring_read(ArctisRing *ring, float *samples, uint32_t frames);
uint64_t arctis_ring_dropped(ArctisRing *ring);
uint32_t arctis_ring_available(ArctisRing *ring);
void arctis_ring_discard(ArctisRing *ring);
#endif
