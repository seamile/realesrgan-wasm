#include "realesrgan.h"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fstream>
#include <iostream>
#include <mutex>
#include <sstream>
#include <sys/stat.h>
#include <thread>
#include <vector>

#include <cpu.h>
#include "shape_layer.h"

namespace {

// Requested concurrent-tile count; 0 means auto-detect.
std::atomic<int> g_cpu_threads(0);

// Upper bound on the starting concurrency. This is not a hard memory limit: a
// model that needs more memory than the 2GB wasm heap allows simply fails, is
// detected, and is retried with fewer tiles (see process()). 8 keeps worker
// creation and scheduling sane while still filling a 16-core machine for the
// light models, which need no more than 512MB in total.
const int kMaxTileThreads = 8;

// ncnn's code for "an allocation failed", i.e. the wasm heap is exhausted.
const int kNcnnOutOfMemory = -100;

// Lowest concurrency that has been enough for a given model in this session,
// so the out-of-memory discovery is paid once per model, not once per image.
// Only ever lowered, and only for the model that actually failed.
std::mutex g_known_limit_mutex;
std::string g_known_limit_model;
int g_known_limit_threads = 0;

// A small image can need fewer tiles than the concurrency we would like; never
// ask for more workers than there is work.
int start_tile_threads(const std::string& model_name)
{
    int n = tile_thread_count();

    std::lock_guard<std::mutex> guard(g_known_limit_mutex);
    if (g_known_limit_threads > 0 && model_name == g_known_limit_model && n > g_known_limit_threads)
        n = g_known_limit_threads;
    return n;
}

void record_known_limit(const std::string& model_name, int num_threads)
{
    std::lock_guard<std::mutex> guard(g_known_limit_mutex);
    g_known_limit_model = model_name;
    g_known_limit_threads = num_threads;
}

} // namespace

int tile_thread_count()
{
    int n = g_cpu_threads.load();
    if (n > 0)
        return n;

    n = ncnn::get_big_cpu_count();
    if (n <= 0)
        n = 1;
    if (n > kMaxTileThreads)
        n = kMaxTileThreads;
    return n;
}

void set_tile_thread_count(int num_threads)
{
    g_cpu_threads.store(num_threads > 0 ? num_threads : 0);
}
RealESRGAN::RealESRGAN()
{
    std::cout << "cpu count: " << ncnn::get_big_cpu_count() << std::endl;
    ncnn::set_cpu_powersave(2);

#ifdef __EMSCRIPTEN__
    // WebAssembly: ncnn stays single-threaded *per extractor*, and the tile loop
    // supplies the parallelism instead (see process()).
    //
    // The only OpenMP runtime available for Emscripten here is ncnn's own
    // simpleomp. With it, the multi-threaded x86 winograd convolution kernels
    // (src/layer/x86/convolution_3x3_winograd.h) produce wrong results, which
    // shows up as NaN / garbled pixels for realesrgan-x4plus and
    // realesrgan-x4plus-anime (the models that actually select winograd).
    // ncnn reads the thread count from the per-extractor Option
    // (`#pragma omp parallel for num_threads(opt.num_threads)`), so pinning
    // opt.num_threads to 1 keeps every layer on simpleomp's inline
    // single-thread path: no simpleomp worker threads are ever created, the
    // winograd kernels stay correct, and separate std::threads running one tile
    // each still use every core. Native builds keep using all cores inside ncnn.
    const int ncnn_threads = 1;
#else
    const int ncnn_threads = ncnn::get_big_cpu_count();
#endif

    ncnn::set_omp_num_threads(ncnn_threads);

    net.opt = ncnn::Option();
    net.opt.num_threads = ncnn_threads;
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

// Emitted after every finished tile. Tile threads call this concurrently, so the
// caller holds progress_mutex to keep whole JSON lines from interleaving.
static void progress_callback(std::chrono::steady_clock::time_point begin, int tiles_done, int total_tiles)
{
    const long total_cost = (long)std::chrono::duration_cast<std::chrono::milliseconds>(
                                std::chrono::steady_clock::now() - begin).count();
    const float progress_rate = total_tiles > 0 ? (float)tiles_done / (float)total_tiles : 1.f;

    // Tiles now run concurrently, so an individual tile's wall time is not a
    // meaningful unit any more; report the average and let remaining_time follow
    // the observed aggregate rate.
    const long tile_cost = tiles_done > 0 ? total_cost / tiles_done : 0;

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
    const std::chrono::steady_clock::time_point begin = std::chrono::steady_clock::now();

    const unsigned char* pixeldata = (const unsigned char*)inimage.data;
    const int w = inimage.w;
    const int h = inimage.h;
    const int channels = inimage.elempack;

    if (channels != 3)
        return -1;

    const int TILE_SIZE_X = tilesize;
    const int TILE_SIZE_Y = tilesize;

    const int xtiles = (w + TILE_SIZE_X - 1) / TILE_SIZE_X;
    const int ytiles = (h + TILE_SIZE_Y - 1) / TILE_SIZE_Y;
    const int total_tiles = xtiles * ytiles;

#ifdef __EMSCRIPTEN__
    // ncnn is pinned to one thread per extractor (see the constructor), so the
    // tile loop is what fills the cores: each in-flight tile runs on its own
    // std::thread. Tiles map to disjoint output regions, so no locking is needed
    // on outimage; the only shared state is the bookkeeping below.
    //
    // How many tiles may be in flight is a memory question, not a core question:
    // every concurrent tile holds its own activations, and the wasm heap is
    // capped at 2GB by MAXIMUM_MEMORY. Measured, realesrgan-x4plus costs roughly
    // 250-300MB per concurrent tile (against ~30MB for the lighter x4v3), so a
    // 16-core machine can only afford about 4-5 of them. Rather than hard-code a
    // per-model number, start at the core count and let the retry loop below
    // halve it whenever ncnn reports that an allocation failed.
    int concurrency = std::min(start_tile_threads(model_name), total_tiles);
    if (concurrency > 1)
        std::cout << "cpu: rendering with " << concurrency << " concurrent tiles" << std::endl;
#else
    // Native: ncnn already parallelises inside each extractor, so running tiles
    // concurrently as well would oversubscribe the machine.
    int concurrency = 1;
#endif

    std::vector<char> tile_done(total_tiles, 0);
    int tiles_left = total_tiles;

    for (;;) // pass loop: repeated with fewer tiles in flight if memory ran out
    {
        std::mutex work_mutex; // guards tile_done, tiles_left and cursor
        std::mutex progress_mutex;
        std::atomic<int> run_status(0);
        int cursor = 0;

        auto render_tiles = [&]()
        {
#ifdef __EMSCRIPTEN__
            // ncnn's kernels read the thread count from the per-extractor
            // Option, but simpleomp also consults this thread's TLS when a
            // parallel region carries no num_threads clause. simpleomp's
            // omp_set_num_threads() writes TLS, so this pins only the current
            // tile thread and leaves the others alone. Native builds must not do
            // this: there the tiles run one at a time and ncnn is what fills the
            // cores.
            ncnn::set_omp_num_threads(1);
#endif

            for (;;)
            {
                if (run_status.load() != 0)
                    return;

                // Poll between tiles: the page's Stop button sets this flag and
                // the run ends here, one tile's worth of work after the click.
                if (cancel_requested())
                {
                    run_status.store(-2);
                    return;
                }

                // Claim the next tile this pass has not rendered yet. The mutex
                // is taken once per tile, which is nothing next to the tile's
                // compute, and it is what keeps the retry pass from redoing work.
                int index;
                {
                    std::lock_guard<std::mutex> guard(work_mutex);
                    if (cursor >= total_tiles)
                        return;
                    index = cursor++;
                    if (tile_done[index])
                        continue;
                }

                const int yi = index / xtiles;
                const int xi = index % xtiles;
                const int tile_w_nopad = std::min((xi + 1) * TILE_SIZE_X, w) - xi * TILE_SIZE_X;
                const int tile_h_nopad = std::min((yi + 1) * TILE_SIZE_Y, h) - yi * TILE_SIZE_Y;

                const int ret = process_tile(pixeldata, w, h, channels, xi, yi,
                                             tile_w_nopad, tile_h_nopad, outimage);
                if (ret != 0)
                {
                    run_status.store(ret);
                    return;
                }

                int done;
                {
                    std::lock_guard<std::mutex> guard(work_mutex);
                    tile_done[index] = 1;
                    tiles_left--;
                    done = total_tiles - tiles_left;
                }
                {
                    std::lock_guard<std::mutex> guard(progress_mutex);
                    progress_callback(begin, done, total_tiles);
                }
            }
        };

        if (concurrency <= 1)
        {
            render_tiles();
        }
        else
        {
            std::vector<std::thread> threads;
            threads.reserve(concurrency);
            for (int i = 0; i < concurrency; i++)
                threads.push_back(std::thread(render_tiles));
            for (size_t i = 0; i < threads.size(); i++)
                threads[i].join();
        }

        // Every tile thread has been joined here, so outimage is either complete
        // or (on cancel) not being written any more: the page can free the output
        // buffer as soon as it sees the callback and never has to guard against a
        // late tile write.
        const int status = run_status.load();
        if (status == 0)
            return 0;
        if (status != kNcnnOutOfMemory || concurrency <= 1)
            return status;

        // The heap hit its 2GB ceiling with `concurrency` tiles in flight. Keep
        // the tiles that finished and retry the rest with half as many.
        const int failed_at = concurrency;
        concurrency = std::max(1, concurrency / 2);
        std::cout << "cpu: not enough memory for " << failed_at
                  << " concurrent tiles, retrying with " << concurrency << std::endl;
        record_known_limit(model_name, concurrency);
    }
}

int RealESRGAN::process_tile(const unsigned char* pixeldata, int w, int h, int channels,
                             int xi, int yi, int tile_w_nopad, int tile_h_nopad,
                             ncnn::Mat& outimage) const
{
    const int TILE_SIZE_X = tilesize;
    const int TILE_SIZE_Y = tilesize;

    const int in_tile_y0 = std::max(yi * TILE_SIZE_Y - prepadding, 0);
    const int in_tile_y1 = std::min((yi + 1) * TILE_SIZE_Y + prepadding, h);
    const int in_tile_x0 = std::max(xi * TILE_SIZE_X - prepadding, 0);
    const int in_tile_x1 = std::min((xi + 1) * TILE_SIZE_X + prepadding, w);

    ncnn::Mat in = ncnn::Mat::from_pixels_roi(
        pixeldata, ncnn::Mat::PIXEL_RGB, w, h,
        in_tile_x0, in_tile_y0,
        in_tile_x1 - in_tile_x0, in_tile_y1 - in_tile_y0);
    if (in.empty())
        return kNcnnOutOfMemory;

    ncnn::Mat in_tile;
    in_tile.create(in.w, in.h, 3);
    if (in_tile.empty())
        return kNcnnOutOfMemory;
    for (int q = 0; q < 3; q++)
    {
        const float* ptr = in.channel(q);
        float* outptr = in_tile.channel(q);
        for (int i = 0; i < in.w * in.h; i++)
            *outptr++ = *ptr++ * (1.f / 255.f);
    }

    {
        const int pad_top = std::max(prepadding - yi * TILE_SIZE_Y, 0);
        const int pad_bottom = std::max(std::min((yi + 1) * TILE_SIZE_Y + prepadding - h, prepadding), 0);
        const int pad_left = std::max(prepadding - xi * TILE_SIZE_X, 0);
        const int pad_right = std::max(std::min((xi + 1) * TILE_SIZE_X + prepadding - w, prepadding), 0);

        ncnn::Mat in_tile_padded;
        ncnn::copy_make_border(in_tile, in_tile_padded,
                               pad_top, pad_bottom, pad_left, pad_right,
                               2, 0.f, net.opt);
        // copy_make_border() is void, so the result is the only way to notice
        // that the padding allocation failed.
        if (in_tile_padded.empty())
            return kNcnnOutOfMemory;
        in_tile = in_tile_padded;
    }

    ncnn::Mat out_tile;
    {
        ncnn::Extractor ex = net.create_extractor();
        int ret = ex.input(input_blob.c_str(), in_tile);
        if (ret != 0)
            return ret;
        ret = ex.extract(output_blob.c_str(), out_tile);
        // Report allocation failures instead of rendering a half-computed tile:
        // silently continuing here used to produce a corrupt image whenever the
        // heap ran out.
        if (ret != 0)
            return ret;
        if (out_tile.empty())
            return kNcnnOutOfMemory;
    }

    ncnn::Mat out;
    out.create(tile_w_nopad * scale, tile_h_nopad * scale, 3);
    if (out.empty())
        return kNcnnOutOfMemory;
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

    return 0;
}
