# XYB PSNR

This branch is an experiment in computing PSNR in the XYB colorspace and reporting a weighted average that may be more perceptually informative. Additionally, it allows providing a per-pixel error map as output, similar to the main project's SSIMULACRA2 error map.

```sh
psnr_diff | [version]

usage:
  psnr_diff [options] <reference> <distorted>

options:
  --json               output result as json
  --err-map <out>      save error map to .png/.tga
  -h, --help           show this help
  -v, --version        show version information

Computes PSNR for X, Y, and B channels (XYB color space) and generates a per-pixel error map.

sRGB PNG, PAM, JPEG, WebP, or AVIF input expected
```

For more articulate help, see the main branch's README.

## License

This branch is still governed by [LICENSE](./LICENSE).
