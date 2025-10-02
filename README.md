# fssimu2

Fast [SSIMULACRA2](https://github.com/cloudinary/ssimulacra2/tree/main) derivative implementation in Zig.

## Usage

```sh
fssimu2 | [version]

usage:
  fssimu2 [options] <reference> <distorted>

options:
  --json               output result as json
  --err-map <out>      save error map to .png/.tga
  -h, --help           show this help
  -v, --version        show version information

sRGB PNG, PAM, JPEG, WebP, or AVIF input expected
```

Example output:
```sh
$ ./ssimu2 ref.png dst.png
79.83781132
```

## Performance

Performance tested on the Intel Core i7 13700k using a 3840x2160 test image. The numbers indicate that this implementation is up to 23% faster and uses ~40% less memory compared to the [reference implementation](https://github.com/cloudinary/ssimulacra2).

```
poop "ssimulacra2 medium.png dst.png" "./ssimu2 medium.png dst.png"
Benchmark 1 (7 runs): ssimulacra2 medium.png dst.png
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           809ms ± 46.8ms     760ms …  857ms          0 ( 0%)        0%
  peak_rss           1.34GB ± 1.51MB    1.34GB … 1.34GB          0 ( 0%)        0%
  cpu_cycles         3.90G  ±  243M     3.65G  … 4.15G           0 ( 0%)        0%
  instructions       9.33G  ± 3.00M     9.32G  … 9.33G           1 (14%)        0%
  cache_references    118M  ± 1.33M      116M  …  119M           0 ( 0%)        0%
  cache_misses       60.0M  ± 3.00M     57.0M  … 63.4M           0 ( 0%)        0%
  branch_misses      16.6M  ±  101K     16.5M  … 16.8M           0 ( 0%)        0%
Benchmark 2 (9 runs): ./ssimu2 medium.png dst.png
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           618ms ± 10.4ms     603ms …  631ms          0 ( 0%)        ⚡- 23.6% ±  4.2%
  peak_rss            817MB ±  118KB     816MB …  817MB          0 ( 0%)        ⚡- 39.1% ±  0.1%
  cpu_cycles         3.05G  ± 45.1M     2.99G  … 3.10G           0 ( 0%)        ⚡- 21.7% ±  4.5%
  instructions       6.17G  ± 24.8M     6.11G  … 6.18G           3 (33%)        ⚡- 33.8% ±  0.2%
  cache_references   74.7M  ± 13.7K     74.7M  … 74.7M           1 (11%)        ⚡- 36.6% ±  0.8%
  cache_misses       34.9M  ±  686K     34.1M  … 35.8M           0 ( 0%)        ⚡- 41.9% ±  3.7%
  branch_misses      11.4M  ±  138K     11.0M  … 11.5M           1 (11%)        ⚡- 31.2% ±  0.8%
```

Conformance to the reference SSIMULACRA2 implementation can be tested with `validate.py` by supplying the `ssimu2` binary.

`validate.py` requires [`uv`](https://docs.astral.sh/uv/) and [`libjxl`](https://github.com/libjxl/libjxl).

```sh
validate.py --custom ~/git-cloning/fssimu2/zig-out/bin/ssimu2 ~/git-cloning/gb82-image-set/png/*
```

Output on the [gb82 image set](https://github.com/gianni-rosato/gb82-image-set) invoking the above command:
```
SAMPLES: 75
LEVELS: 1.0 2.0 4.0

== custom vs ref ==
 pairs: 75
 ref mean: 77.5116  std: 10.6899
 custom mean: 76.9932  std: 11.1606
 mean diff (other - ref): -0.518406
 diff stddev: 0.541576
 diff stderr: 0.0625359
 percentage error (mean diff / ref mean): 0.669%
 max absolute error: 1.9165

== correlation ==
 PCC (Pearson): 0.999700
 SRCC (Spearman): 0.999403
 KRCC (Kendall): 0.987748
```

## Error Map

The `ssimu2` binary optionally allows specifying an error map output image as either an uncompressed `.tga` (Targa) or PNG.

Error maps use the [Turbo](https://research.google/blog/turbo-an-improved-rainbow-colormap-for-visualization/) color map for error visualization, which emphasizes visually obvious errors well.

An example output is provided here, generated using `./ssimu2 --err-map map.png ref.png dst_bad.png` which resulted in a score of `49.37005220`.

![Sample Error Map](./map.webp)

## Compilation

Compilation requires:
- Zig (version [0.15.1](https://ziglang.org/download/0.15.1/release-notes.html))
- [libjpeg-turbo](https://libjpeg-turbo.org)
- [libwebp](https://chromium.googlesource.com/webm/libwebp)
- [libavif](https://github.com/AOMediaCodec/libavif)

Run `zig build --release=fast`, and the binary will emit to `zig-out/bin/ssimu2`. The library will emit to `zig-out/lib/libssimu2.so` (or .dylib on macOS, .dll on Windows) and the include will be moved to `zig-out/include/ssimu2.h`.

## C ABI

`fssimu2` provides a C-compatible ABI with the `ssimu2.h` include file.

### Header

The exposed functionality is as follows:

```c
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
    const double *out_score
);
```

### Example Usage

An example C program is provided in the `c_abi_example/` directory, featuring a simple PAM decoder and SSIMULACRA2 computation. See the `test.c` file for usage.

In order to build the test example, enter the `c_abi_example/` dir and run:
```sh
cc test.c pam_dec.c -I../zig-out/include -L../zig-out/lib -lssimu2 -o test
# Set library path for Linux
LD_LIBRARY_PATH=../zig-out/lib ./test ref.pam dst.pam
# Set library path for macOS
DYLD_LIBRARY_PATH=../zig-out/lib ./test ref.pam dst.pam
```

When fssimu2 is properly installed system-wide, the library path specifier isn't needed.

## License

This project is under the Apache 2.0 license. More details in [LICENSE](./LICENSE).

This project uses code from [libspng](https://libspng.org), [libminiz](https://github.com/richgel999/miniz), and [vapoursynth-zip](https://github.com/dnjulek/vapoursynth-zip). Special thanks to the authors. Licenses for third party code are included in the `legal/` folder.
