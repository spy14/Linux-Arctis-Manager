#include "../Sources/AudioRing.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    ArctisRing *ring = arctis_ring_create(2, 4);
    assert(ring);
    float in[] = {1,2,3,4,5,6,7,8};
    float out[8];
    arctis_ring_write(ring, in, 3);
    assert(arctis_ring_available(ring) == 3);
    arctis_ring_read(ring, out, 2);
    assert(out[0] == 1 && out[3] == 4);
    arctis_ring_write(ring, in, 3); // wraps
    arctis_ring_write(ring, in, 1); // overflow cannot overwrite unread frames
    assert(arctis_ring_dropped(ring) == 1);
    arctis_ring_read(ring, out, 4);
    assert(out[0] == 5 && out[1] == 6 && out[2] == 1 && out[7] == 6);
    arctis_ring_read(ring, out, 4);
    for (int i = 0; i < 8; ++i) assert(out[i] == 0);
    arctis_ring_destroy(ring);
    assert(!arctis_ring_create(0, 4));
    puts("Audio ring tests passed");
}
