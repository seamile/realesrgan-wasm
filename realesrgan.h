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
    ncnn::Net net;
};

#endif // REALESRGAN_H
