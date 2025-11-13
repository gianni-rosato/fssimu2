#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "pam_dec.h"
#include "../zig-out/include/ssimu2.h"

static void freeImage(Image* const img) {
    if (img) {
        free(img->data);
        free(img);
    }
}

// Write PAM image with RGBA data
int write_pam_rgba(const char* filename, uint32_t width, uint32_t height, uint32_t* data) {
    FILE* file = fopen(filename, "wb");
    if (!file) {
        printf("Failed to open file for writing: %s\n", filename);
        return 0;
    }

    fprintf(file, "P7\n");
    fprintf(file, "WIDTH %u\n", width);
    fprintf(file, "HEIGHT %u\n", height);
    fprintf(file, "DEPTH 4\n");
    fprintf(file, "MAXVAL 255\n");
    fprintf(file, "TUPLTYPE RGB_ALPHA\n");
    fprintf(file, "ENDHDR\n");

    for (uint32_t i = 0; i < width * height; i++) {
        uint32_t pixel = data[i];
        uint8_t r = pixel & 0xFF;
        uint8_t g = (pixel >> 8) & 0xFF;
        uint8_t b = (pixel >> 16) & 0xFF;
        uint8_t a = (pixel >> 24) & 0xFF;

        fwrite(&r, 1, 1, file);
        fwrite(&g, 1, 1, file);
        fwrite(&b, 1, 1, file);
        fwrite(&a, 1, 1, file);
    }

    fclose(file);
    return 1;
}

int main(int argc, const char* argv[]) {
    if (argc != 3 && argc != 4) {
        printf("Usage: %s <reference.pam> <distorted.pam> [output_map.pam]\n", argv[0]);
        printf("If output_map.pam is provided, the distortion map will be saved as a PAM file\n");
        return 1;
    }

    Image* const ref = loadPAM(argv[1]);
    if (!ref) {
        printf("Failed to load reference image: %s\n", argv[1]);
        return 1;
    }

    Image* const dist = loadPAM(argv[2]);
    if (!dist) {
        printf("Failed to load distorted image: %s\n", argv[2]);
        freeImage(ref);
        return 1;
    }

    if (ref->width != dist->width || ref->height != dist->height || ref->channels != dist->channels) {
        printf("Images must have the same dimensions and number of channels\n");
        printf("Reference: %ux%u, %u channels\n", ref->width, ref->height, ref->channels);
        printf("Distorted: %ux%u, %u channels\n", dist->width, dist->height, dist->channels);
        freeImage(ref);
        freeImage(dist);
        return 1;
    }

    // Allocate memory for distortion map
    uint32_t* error_map = malloc(ref->width * ref->height * sizeof(uint32_t));
    if (!error_map) {
        printf("Failed to allocate memory for distortion map\n");
        freeImage(ref);
        freeImage(dist);
        return 1;
    }

    double score;
    const int err = ssimulacra2_score_with_map(
        ref->data,
        dist->data,
        ref->width,
        ref->height,
        ref->channels,
        &score,
        error_map
    );

    if (err == SSIMU2_OK) {
        printf("SSIMULACRA2 Score: %.6f\n", score);

        // Save distortion map if output file specified
        if (argc == 4) {
            if (write_pam_rgba(argv[3], ref->width, ref->height, error_map)) {
                printf("Distortion map saved to: %s\n", argv[3]);

                // Print some sample values for debugging
                printf("Sample distortion map values (first 5 pixels, RGBA):\n");
                for (int i = 0; i < 5 && i < ref->width * ref->height; i++) {
                    uint32_t pixel = error_map[i];
                    printf("  Pixel %d: R=%3u, G=%3u, B=%3u, A=%3u\n",
                           i,
                           pixel & 0xFF,
                           (pixel >> 8) & 0xFF,
                           (pixel >> 16) & 0xFF,
                           (pixel >> 24) & 0xFF);
                }
            } else printf("Failed to save distortion map to: %s\n", argv[3]);
        }
    } else if (err == SSIMU2_INVALID_CHANNELS)
        printf("Error: Invalid number of channels (must be 3 or 4)\n");
    else if (err == SSIMU2_OUT_OF_MEMORY)
        printf("Error: Out of memory\n");
    else printf("Unknown error: %d\n", err);

    free(error_map);
    freeImage(ref);
    freeImage(dist);
    return 0;
}
