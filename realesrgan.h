#ifndef REALESRGAN_H
#define REALESRGAN_H

#include <string>
#include <vector>
#include "net.h"

struct ModelInfo
{
    std::string name;       // basename without extension
    std::string param_path;
    std::string bin_path;
    std::string input_blob;
    std::string output_blob;
    int scale;
};

// Scan the Emscripten MEMFS working directory for *.param + matching *.bin.
// The page downloads the selected model and writes both files there at runtime.
int scan_models(std::vector<ModelInfo>& out);

// Guess scale from model file name.
int guess_scale_from_name(const std::string& name);

// Read Input / final output blob names from an ncnn .param file.
int parse_param_blobs(const std::string& param_path, std::string& input_blob, std::string& output_blob);

// Cooperative cancellation hook, implemented by the host translation unit
// (main.cpp). The tile loop polls it between tiles, so a Stop click ends a long
// CPU run within roughly one tile instead of after the whole image.
bool cancel_requested();

// Number of tiles rendered concurrently by RealESRGAN::process() on WebAssembly.
// 0 (the default) auto-detects from the runtime's logical core count.
// tile_thread_count() returns the count the next run will start with. Only
// WebAssembly uses this: native builds let ncnn parallelise inside each extractor
// instead. main.cpp re-exports these as set_cpu_threads() / get_cpu_threads()
// for the page.
void set_tile_thread_count(int num_threads);
int tile_thread_count();

class RealESRGAN
{
public:
    RealESRGAN();
    ~RealESRGAN();

    int load(const ModelInfo& info);
    int process(const ncnn::Mat& inimage, ncnn::Mat& outimage);

public:
    int scale;
    int tilesize;
    int prepadding;
    std::string model_name;
    std::string input_blob;
    std::string output_blob;

private:
    // Renders a single tile and writes it into its own region of outimage. Tiles
    // touch disjoint output rows/columns, so concurrent calls for distinct
    // (xi, yi) are safe. Returns 0, or ncnn's error code on failure (notably
    // -100 when the wasm heap is exhausted).
    int process_tile(const unsigned char* pixeldata, int w, int h, int channels,
                     int xi, int yi, int tile_w_nopad, int tile_h_nopad,
                     ncnn::Mat& outimage) const;

    ncnn::Net net;
};

#endif // REALESRGAN_H
