// Phase 4: headless automated validation (--smoke-test).
//
// Gates (all headless, no SDL/OpenGL):
//   1. image-load   : every bundled assets/ image loads through a known profile
//   2. basic-capture: each image yields a clean 559x192 frame (107,328 px,
//                     192 lines, 0 bad widths)
//   3. settings-matrix: display(4) x palette(3 built-in) x seam(2) x
//                     comb(2) x color-line(2) on a representative image
//   4. bw-mono      : B&W + COLOR_LINE=none -> every pixel R=G=B
//   5. determinism  : two clean DUT reconstructions produce byte-identical
//                     frames (FNV-1a hash compare)
//   6. alignment    : B&W capture matches the thresholded source within <1%
//                     at the best circular shift (guards the feeder's column
//                     indexing - the original 196-sample rotation bug)
//   7. bad-size     : unsupported image dimensions fail cleanly
//
// On any gate failure the failing frame (when available) is dumped to
// output/smoke_fail_<gate>.ppm for inspection.

#pragma once

int run_smoke_test();
