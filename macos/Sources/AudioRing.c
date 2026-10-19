#include "AudioRing.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
struct ArctisRing {
    uint32_t channels, capacity;
    _Atomic uint64_t read, write, dropped;
    float *data;
};
ArctisRing *arctis_ring_create(uint32_t channels, uint32_t capacity) {
    if (!channels || channels > 8 || !capacity || capacity > 1048576) return NULL;
    ArctisRing *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->data = calloc((size_t)channels * capacity, sizeof(float));
    if (!r->data) { free(r); return NULL; }
    r->channels = channels; r->capacity = capacity;
    return r;
}
void arctis_ring_destroy(ArctisRing *r) { if (r) { free(r->data); free(r); } }
void arctis_ring_write(ArctisRing *r, const float *samples, uint32_t frames) {
    uint64_t w = atomic_load_explicit(&r->write, memory_order_relaxed);
    uint64_t rd = atomic_load_explicit(&r->read, memory_order_acquire);
    if (frames > r->capacity - (w - rd)) { atomic_fetch_add(&r->dropped, frames); return; }
    for (uint32_t f = 0; f < frames; ++f)
        memcpy(r->data + ((w + f) % r->capacity) * r->channels,
               samples + (size_t)f * r->channels, sizeof(float) * r->channels);
    atomic_store_explicit(&r->write, w + frames, memory_order_release);
}
void arctis_ring_read(ArctisRing *r, float *samples, uint32_t frames) {
    uint64_t rd = atomic_load_explicit(&r->read, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&r->write, memory_order_acquire);
    uint32_t available = (uint32_t)(w - rd);
    uint32_t count = frames < available ? frames : available;
    for (uint32_t f = 0; f < count; ++f)
        memcpy(samples + (size_t)f * r->channels,
               r->data + ((rd + f) % r->capacity) * r->channels, sizeof(float) * r->channels);
    memset(samples + (size_t)count * r->channels, 0, sizeof(float) * (frames - count) * r->channels);
    atomic_store_explicit(&r->read, rd + count, memory_order_release);
}
uint64_t arctis_ring_dropped(ArctisRing *r) { return atomic_load(&r->dropped); }
uint32_t arctis_ring_available(ArctisRing *r) {
    uint64_t rd = atomic_load_explicit(&r->read, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&r->write, memory_order_acquire);
    return (uint32_t)(w - rd);
}
void arctis_ring_discard(ArctisRing *r) {
    uint64_t w = atomic_load_explicit(&r->write, memory_order_acquire);
    atomic_store_explicit(&r->read, w, memory_order_release);
}
