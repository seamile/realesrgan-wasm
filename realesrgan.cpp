#include "realesrgan.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fstream>
#include <iostream>
#include <sstream>
#include <sys/stat.h>

#include <cpu.h>
#include "shape_layer.h"

RealESRGAN::RealESRGAN()
{
    std::cout << "cpu count: " << ncnn::get_big_cpu_count() << std::endl;
    ncnn::set_cpu_powersave(2);
    ncnn::set_omp_num_threads(ncnn::get_big_cpu_count());

    net.opt = ncnn::Option();
    net.opt.num_threads = ncnn::get_big_cpu_count();
    net.opt.use_vulkan_compute = false;

    scale = 4;
    tilesize = 64;
    prepadding = 10;
    input_blob = "data";
    output_blob = "output";
}

RealESRGAN::~RealESRGAN()
{
    net.clear();
}

static std::string to_lower(std::string s)
{
    for (size_t i = 0; i < s.size(); i++)
        s[i] = (char)std::tolower((unsigned char)s[i]);
    return s;
}

int guess_scale_from_name(const std::string& name)
{
    const std::string n = to_lower(name);

    // More specific patterns first.
    if (n.find("x2plus") != std::string::npos
        || n.find("xsx2") != std::string::npos
        || (n.size() >= 3 && n.compare(n.size() - 3, 3, "-x2") == 0)
        || n.find("-x2-") != std::string::npos
        || n.find("_x2_") != std::string::npos
        || n.find("_x2.") != std::string::npos
        || n.find("2x-") == 0
        || n.find("-2x") != std::string::npos)
    {
        return 2;
    }

    if (n.find("xsx3") != std::string::npos
        || (n.size() >= 3 && n.compare(n.size() - 3, 3, "-x3") == 0)
        || n.find("-x3-") != std::string::npos
        || n.find("_x3_") != std::string::npos
        || n.find("3x-") == 0
        || n.find("-3x") != std::string::npos)
    {
        return 3;
    }

    if (n.find("x4v3") != std::string::npos
        || n.find("x4plus") != std::string::npos
        || n.find("xsx4") != std::string::npos
        || (n.size() >= 3 && n.compare(n.size() - 3, 3, "-x4") == 0)
        || n.find("-x4-") != std::string::npos
        || n.find("_x4") != std::string::npos
        || n.find("x4") != std::string::npos
        || n.find("4x") != std::string::npos)
    {
        return 4;
    }

    // Default to 4x for unknown Real-ESRGAN-style weights.
    return 4;
}

static bool file_exists(const std::string& path)
{
    struct stat st;
    return stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

int parse_param_blobs(const std::string& param_path, std::string& input_blob, std::string& output_blob)
{
    input_blob.clear();
    output_blob.clear();

    std::ifstream ifs(param_path.c_str());
    if (!ifs.is_open())
        return -1;

    std::string line;
    // Skip magic + layer/blob counts
    if (!std::getline(ifs, line)) return -1;
    if (!std::getline(ifs, line)) return -1;

    std::string last_output_blob;
    while (std::getline(ifs, line))
    {
        if (line.empty())
            continue;

        std::istringstream iss(line);
        std::string type, name;
        int bottom_count = 0;
        int top_count = 0;
        if (!(iss >> type >> name >> bottom_count >> top_count))
            continue;

        std::vector<std::string> bottoms(bottom_count);
        std::vector<std::string> tops(top_count);
        for (int i = 0; i < bottom_count; i++)
            iss >> bottoms[i];
        for (int i = 0; i < top_count; i++)
            iss >> tops[i];

        if (type == "Input" && !tops.empty() && input_blob.empty())
            input_blob = tops[0];

        if (!tops.empty())
            last_output_blob = tops[0];
    }

    if (input_blob.empty())
        input_blob = "data";
    output_blob = last_output_blob.empty() ? "output" : last_output_blob;
    return 0;
}

int scan_models(std::vector<ModelInfo>& out)
{
    out.clear();

    DIR* dir = opendir(".");
    if (!dir)
    {
        std::cerr << "opendir(.) failed" << std::endl;
        return -1;
    }

    std::vector<std::string> param_names;
    struct dirent* ent;
    while ((ent = readdir(dir)) != NULL)
    {
        std::string fname = ent->d_name;
        if (fname.size() > 6 && fname.compare(fname.size() - 6, 6, ".param") == 0)
            param_names.push_back(fname.substr(0, fname.size() - 6));
    }
    closedir(dir);

    std::sort(param_names.begin(), param_names.end());

    for (size_t i = 0; i < param_names.size(); i++)
    {
        const std::string& name = param_names[i];
        const std::string param_path = name + ".param";
        const std::string bin_path = name + ".bin";
        if (!file_exists(bin_path))
        {
            std::cerr << "skip model without bin: " << name << std::endl;
            continue;
        }

        ModelInfo info;
        info.name = name;
        info.param_path = param_path;
        info.bin_path = bin_path;
        info.scale = guess_scale_from_name(name);
        if (parse_param_blobs(param_path, info.input_blob, info.output_blob) != 0)
        {
            info.input_blob = "data";
            info.output_blob = "output";
        }

        out.push_back(info);
        std::cout << "found model: " << info.name
                  << " scale=" << info.scale
                  << " in=" << info.input_blob
                  << " out=" << info.output_blob
                  << std::endl;
    }

    return (int)out.size();
}

static void progress_callback(long total_cost, long tile_cost, float progress_rate)
{
    long remaining_time = 0;
    if (progress_rate != 0)
        remaining_time = (long)((float)total_cost / progress_rate - (float)total_cost);

    char script[256];
    snprintf(script, sizeof(script),
             "$CALLBACK$ {\"eventType\":\"PROC_PROGRESS\",\"total_cost\":%ld,\"tile_cost\":%ld,\"progress_rate\":%f,\"remaining_time\":%ld}",
             total_cost, tile_cost, progress_rate, remaining_time);
    std::cout << script << std::endl;
}

int RealESRGAN::load(const ModelInfo& info)
{
    net.clear();
    // Required by ONNX-converted models that still contain Shape ops.
    net.register_custom_layer("Shape", Shape_layer_creator);

    model_name = info.name;
    scale = info.scale;
    input_blob = info.input_blob;
    output_blob = info.output_blob;
    prepadding = 10;
    tilesize = 64;

    int ret = net.load_param(info.param_path.c_str());
    if (ret != 0)
    {
        std::cerr << "load_param failed: " << info.param_path
                  << " (unsupported layer? try a properly converted ncnn model)" << std::endl;
        model_name.clear();
        return -1;
    }
    ret = net.load_model(info.bin_path.c_str());
    if (ret != 0)
    {
        std::cerr << "load_model failed: " << info.bin_path << std::endl;
        model_name.clear();
        return -1;
    }

    std::cout << "model loaded: " << model_name
              << " scale=" << scale
              << " in=" << input_blob
              << " out=" << output_blob
              << " tilesize=" << tilesize
              << std::endl;
    return 0;
}

int RealESRGAN::process(const ncnn::Mat& inimage, ncnn::Mat& outimage)
{
    std::chrono::steady_clock::time_point begin = std::chrono::steady_clock::now();

    const unsigned char* pixeldata = (const unsigned char*)inimage.data;
    const int w = inimage.w;
    const int h = inimage.h;
    const int channels = inimage.elempack;

    const int TILE_SIZE_X = tilesize;
    const int TILE_SIZE_Y = tilesize;

    const int xtiles = (w + TILE_SIZE_X - 1) / TILE_SIZE_X;
    const int ytiles = (h + TILE_SIZE_Y - 1) / TILE_SIZE_Y;

    for (int yi = 0; yi < ytiles; yi++)
    {
        const int tile_h_nopad = std::min((yi + 1) * TILE_SIZE_Y, h) - yi * TILE_SIZE_Y;

        int in_tile_y0 = std::max(yi * TILE_SIZE_Y - prepadding, 0);
        int in_tile_y1 = std::min((yi + 1) * TILE_SIZE_Y + prepadding, h);

        for (int xi = 0; xi < xtiles; xi++)
        {
            std::chrono::steady_clock::time_point tile_begin = std::chrono::steady_clock::now();

            const int tile_w_nopad = std::min((xi + 1) * TILE_SIZE_X, w) - xi * TILE_SIZE_X;

            int in_tile_x0 = std::max(xi * TILE_SIZE_X - prepadding, 0);
            int in_tile_x1 = std::min((xi + 1) * TILE_SIZE_X + prepadding, w);

            ncnn::Mat in;
            if (channels == 3)
            {
                in = ncnn::Mat::from_pixels_roi(
                    pixeldata, ncnn::Mat::PIXEL_RGB, w, h,
                    in_tile_x0, in_tile_y0,
                    in_tile_x1 - in_tile_x0, in_tile_y1 - in_tile_y0);
            }
            else
            {
                return -1;
            }

            ncnn::Mat in_tile;
            in_tile.create(in.w, in.h, 3);
            for (int q = 0; q < 3; q++)
            {
                const float* ptr = in.channel(q);
                float* outptr = in_tile.channel(q);
                for (int i = 0; i < in.w * in.h; i++)
                    *outptr++ = *ptr++ * (1.f / 255.f);
            }

            {
                int pad_top = std::max(prepadding - yi * TILE_SIZE_Y, 0);
                int pad_bottom = std::max(std::min((yi + 1) * TILE_SIZE_Y + prepadding - h, prepadding), 0);
                int pad_left = std::max(prepadding - xi * TILE_SIZE_X, 0);
                int pad_right = std::max(std::min((xi + 1) * TILE_SIZE_X + prepadding - w, prepadding), 0);

                ncnn::Mat in_tile_padded;
                ncnn::copy_make_border(in_tile, in_tile_padded,
                                       pad_top, pad_bottom, pad_left, pad_right,
                                       2, 0.f, net.opt);
                in_tile = in_tile_padded;
            }

            ncnn::Mat out_tile;
            {
                ncnn::Extractor ex = net.create_extractor();
                ex.input(input_blob.c_str(), in_tile);
                ex.extract(output_blob.c_str(), out_tile);
            }

            ncnn::Mat out;
            out.create(tile_w_nopad * scale, tile_h_nopad * scale, 3);
            const int pad_out = prepadding * scale;

            // Guard against models whose output is exactly nopad*scale (no padding).
            const int use_crop = (out_tile.w >= out.w + pad_out && out_tile.h >= out.h + pad_out) ? 1 : 0;
            const int x0 = use_crop ? pad_out : 0;
            const int y0 = use_crop ? pad_out : 0;

            for (int q = 0; q < 3; q++)
            {
                float* outptr = out.channel(q);
                for (int i = 0; i < out.h; i++)
                {
                    const float* ptr = out_tile.channel(q).row(y0 + i) + x0;
                    for (int j = 0; j < out.w; j++)
                    {
                        float v = ptr[j] * 255.f + 0.5f;
                        if (v > 255.f) v = 255.f;
                        if (v < 0.f) v = 0.f;
                        *outptr++ = v;
                    }
                }
            }

            out.to_pixels(
                (unsigned char*)outimage.data
                    + yi * scale * TILE_SIZE_Y * w * scale * channels
                    + xi * scale * TILE_SIZE_X * channels,
                ncnn::Mat::PIXEL_RGB,
                w * scale * channels);

            auto end = std::chrono::steady_clock::now();
            auto tile_cost = std::chrono::duration_cast<std::chrono::milliseconds>(end - tile_begin).count();
            auto total_cost = std::chrono::duration_cast<std::chrono::milliseconds>(end - begin).count();
            float progress_rate = (float)(xtiles * yi + xi + 1) / (float)(xtiles * ytiles);
            progress_callback(total_cost, tile_cost, progress_rate);
        }
    }

    return 0;
}
