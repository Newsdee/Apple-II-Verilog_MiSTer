// Implementation of image_source.h.

#define STB_IMAGE_IMPLEMENTATION
#include "third_party/stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "third_party/stb_image_write.h"

#include "image_source.h"

#include <cstdio>

bool load_image_1bit(const std::string& path, int threshold,
                     Image1Bit* out, std::string* error) {
    if (threshold < 0 || threshold > 255) {
        *error = "threshold out of range 0..255";
        return false;
    }

    int w = 0, h = 0, comp = 0;
    unsigned char* px =
        stbi_load(path.c_str(), &w, &h, &comp, 3);  // force RGB
    if (!px) {
        *error = std::string("cannot load image: ") + stbi_failure_reason();
        return false;
    }
    out->src_width = w;
    out->src_height = h;

    auto src_bit = [&](int y, int x) -> uint8_t {
        const size_t i = ((size_t)y * w + x) * 3;
        const int r = px[i], g = px[i + 1], b = px[i + 2];
        const int luma = (r * 77 + g * 150 + b * 29) >> 8;
        return (uint8_t)(luma >= threshold);
    };

    out->bits.assign((size_t)Image1Bit::kWidth * Image1Bit::kHeight, 0);

    if (h == Image1Bit::kHeight && w == 280) {
        out->profile = "280x192 dup";
        for (int y = 0; y < Image1Bit::kHeight; ++y)
            for (int x = 0; x < Image1Bit::kWidth; ++x)
                out->bits[(size_t)y * Image1Bit::kWidth + x] = src_bit(y, x / 2);
    } else if (h == Image1Bit::kHeight && w == 284) {
        out->profile = "284x192 crop2+dup";
        for (int y = 0; y < Image1Bit::kHeight; ++y)
            for (int x = 0; x < Image1Bit::kWidth; ++x)
                out->bits[(size_t)y * Image1Bit::kWidth + x] =
                    src_bit(y, 2 + (x / 2));
    } else if (h == Image1Bit::kHeight && w == 560) {
        out->profile = "560x192 direct";
        for (int y = 0; y < Image1Bit::kHeight; ++y)
            for (int x = 0; x < Image1Bit::kWidth; ++x)
                out->bits[(size_t)y * Image1Bit::kWidth + x] = src_bit(y, x);
    } else if (h == Image1Bit::kHeight && w == 568) {
        out->profile = "568x192 crop4";
        for (int y = 0; y < Image1Bit::kHeight; ++y)
            for (int x = 0; x < Image1Bit::kWidth; ++x)
                out->bits[(size_t)y * Image1Bit::kWidth + x] =
                    src_bit(y, 4 + x);
    } else {
        char buf[128];
        snprintf(buf, sizeof(buf),
                 "unsupported image size %dx%d (need 280/284/560/568 x 192)",
                 w, h);
        *error = buf;
        stbi_image_free(px);
        return false;
    }

    stbi_image_free(px);
    return true;
}
