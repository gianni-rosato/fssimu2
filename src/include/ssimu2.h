#ifndef SSIMULACRA2_H
#define SSIMULACRA2_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

#define SSIMU2_OK 0
#define SSIMU2_INVALID_CHANNELS 1
#define SSIMU2_OUT_OF_MEMORY 2

// Compute a SSIMULACRA2 score
// The caller must ensure that the reference and distorted buffers
// are at least (width * height * channels) bytes long. If not,
// could lead to UB in ReleaseFast
int ssimulacra2_score(
    const uint8_t *reference,
    const uint8_t *distorted,
    const unsigned width,
    const unsigned height,
    const unsigned channels,
    double *out_score
);

// Compute a SSIMULACRA2 score with distortion map
// The caller must ensure that the reference and distorted buffers
// are at least (width * height * channels) bytes long.
// The error_map buffer must be at least (width * height * 4) bytes long
// and will be filled with RGBA values representing the distortion map.
int ssimulacra2_score_with_map(
    const uint8_t *reference,
    const uint8_t *distorted,
    const unsigned width,
    const unsigned height,
    const unsigned channels,
    double *out_score,
    uint32_t *error_map
);

#ifdef __cplusplus
}
#endif

#endif // SSIMULACRA2_H
