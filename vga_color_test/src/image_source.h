// 1-bit Apple II image source for the VGA color tester.
//
// Loads a PNG/BMP, converts it to a single video bit per sample using a
// luminance threshold, and maps it to the 560x192 active source region the
// VGA controller consumes. Color in the source image is ignored after
// thresholding (Apple II video is 1 bit).
//
// Supported input profiles (PLAN.md, Phase 2):
//   280x192 : duplicate each source pixel horizontally (280*2 = 560)
//   284x192 : crop 2 px from each side -> 280, then duplicate
//   560x192 : feed directly
//   559x192 : feed 559 directly, pad the 560th sample with the last column
//             (the DUT drops the 560th sample anyway - 559 is its output width)
//   568x192 : crop 4 px from each side -> 560
// Anything else is rejected with a descriptive error (no rescaling).

#pragma once

#include <cstdint>
#include <string>
#include <vector>

struct Image1Bit {
    static constexpr int kWidth = 560;   // active source samples per line
    static constexpr int kHeight = 192;  // active source lines

    // Row-major, one bit per byte (0 or 1), kWidth * kHeight entries.
    std::vector<uint8_t> bits;
    int src_width = 0;   // original loaded image size (for status text)
    int src_height = 0;
    std::string profile; // e.g. "284x192 crop2+dup"

    bool valid() const {
        return bits.size() == (size_t)kWidth * kHeight;
    }
    uint8_t at(int y, int x) const { return bits[(size_t)y * kWidth + x]; }
};

// Load `path`, threshold to 1 bit, and map to the 560x192 source region.
// On failure returns false and fills `error` (non-empty).
bool load_image_1bit(const std::string& path, int threshold,
                     Image1Bit* out, std::string* error);
