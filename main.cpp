#include <chrono>
#include <atomic>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

#include <cpu.h>
#include <cstdio>
#include "realesrgan.h"

class Task
{
public:
    int image_id;
    unsigned char* input_image_data;
    unsigned char* output_image_data;
    int input_w;
    int input_h;
    int input_channel;
    int model_index;
};

static ncnn::Mutex lock;
static ncnn::ConditionVariable condition;
static RealESRGAN* realesrgan = nullptr;
static Task* proc_img_task = nullptr;
static std::vector<ModelInfo> g_models;

// Set by the page's Stop button through cancel_process() and polled by the tile
// loop via cancel_requested(). Atomic because the worker thread reads it while
// the main (browser) thread writes it.
static std::atomic<bool> g_cancel(false);

bool cancel_requested()
{
    return g_cancel.load();
}

static ncnn::Mutex finish_lock;
static ncnn::ConditionVariable finish_condition;

void remove_alpha_channel(unsigned char* image_data, int w, int h)
{
    for (int i = 0; i < w * h; i++)
    {
        image_data[i * 3] = image_data[i * 4];
        image_data[i * 3 + 1] = image_data[i * 4 + 1];
        image_data[i * 3 + 2] = image_data[i * 4 + 2];
    }
}

void copy_with_alpha_channel(unsigned char* dst, const unsigned char* src, int w, int h)
{
    for (int i = 0; i < w * h; i++)
    {
        dst[0] = src[0];
        dst[1] = src[1];
        dst[2] = src[2];
        dst[3] = 255;
        dst += 4;
        src += 3;
    }
}

void process_image_success_callback(int image_id, long cost)
{
    char script[128];
    snprintf(script, sizeof(script),
             "$CALLBACK$ {\"eventType\": \"PROC_END\", \"image_id\": %d, \"cost\": %ld}",
             image_id, cost);
    std::cout << script << std::endl;
}

static void worker()
{
    while (1)
    {
        lock.lock();
        while (proc_img_task == nullptr)
        {
            condition.wait(lock);
        }

        std::chrono::steady_clock::time_point begin = std::chrono::steady_clock::now();
        std::cout << "thread process start" << std::endl;

        if (proc_img_task->model_index < 0 || proc_img_task->model_index >= (int)g_models.size())
        {
            std::cerr << "invalid model_index: " << proc_img_task->model_index << std::endl;
            process_image_success_callback(proc_img_task->image_id, -1);
            delete proc_img_task;
            proc_img_task = nullptr;
            lock.unlock();
            finish_lock.lock();
            finish_condition.signal();
            finish_lock.unlock();
            continue;
        }

        const ModelInfo& info = g_models[proc_img_task->model_index];
        if (!realesrgan)
            realesrgan = new RealESRGAN();

        if (realesrgan->model_name != info.name)
        {
            if (realesrgan->load(info) != 0)
            {
                std::cerr << "failed to load model: " << info.name << std::endl;
                process_image_success_callback(proc_img_task->image_id, -1);
                delete proc_img_task;
                proc_img_task = nullptr;
                lock.unlock();
                finish_lock.lock();
                finish_condition.signal();
                finish_lock.unlock();
                continue;
            }
        }

        if (realesrgan->model_name.empty())
        {
            std::cerr << "no model loaded" << std::endl;
            process_image_success_callback(proc_img_task->image_id, -1);
            delete proc_img_task;
            proc_img_task = nullptr;
            lock.unlock();
            finish_lock.lock();
            finish_condition.signal();
            finish_lock.unlock();
            continue;
        }

        ncnn::Mat inImage = ncnn::Mat(
            proc_img_task->input_w,
            proc_img_task->input_h,
            (void*)proc_img_task->input_image_data,
            (size_t)proc_img_task->input_channel,
            proc_img_task->input_channel);

        ncnn::Mat outImage = ncnn::Mat(
            inImage.w * realesrgan->scale,
            inImage.h * realesrgan->scale,
            (size_t)inImage.elemsize,
            (int)inImage.elemsize);

        const int process_ret = realesrgan->process(inImage, outImage);
        if (process_ret == 0)
        {
            copy_with_alpha_channel(
                proc_img_task->output_image_data,
                (const unsigned char*)outImage.data,
                outImage.w,
                outImage.h);

            std::chrono::steady_clock::time_point end = std::chrono::steady_clock::now();
            auto cost = std::chrono::duration_cast<std::chrono::milliseconds>(end - begin).count();
            std::cout << "thread process done, cost: " << cost / 1000.0 << " secs" << std::endl;
            process_image_success_callback(proc_img_task->image_id, cost);
        }
        else
        {
            // -2 means the page asked to stop. The output buffer is left
            // untouched, so the page can free it as soon as it sees this
            // callback and never has to guard against a late tile write.
            std::cout << "thread process stopped, ret: " << process_ret << std::endl;
            process_image_success_callback(proc_img_task->image_id, process_ret == -2 ? -2 : -1);
        }
        delete proc_img_task;
        proc_img_task = nullptr;
        lock.unlock();

        finish_lock.lock();
        finish_condition.signal();
        finish_lock.unlock();
    }
}

static std::thread t(worker);

extern "C"
{

int list_models()
{
    scan_models(g_models);
    return (int)g_models.size();
}

int get_model_count()
{
    return (int)g_models.size();
}

// Pointer remains valid until next list_models().
const char* get_model_name(int index)
{
    if (index < 0 || index >= (int)g_models.size())
        return "";
    return g_models[index].name.c_str();
}

int get_model_scale(int index)
{
    if (index < 0 || index >= (int)g_models.size())
        return 0;
    return g_models[index].scale;
}

const char* get_model_input_blob(int index)
{
    if (index < 0 || index >= (int)g_models.size())
        return "";
    return g_models[index].input_blob.c_str();
}

const char* get_model_output_blob(int index)
{
    if (index < 0 || index >= (int)g_models.size())
        return "";
    return g_models[index].output_blob.c_str();
}

int process_image(int image_id,
                  unsigned char* input_image_data,
                  unsigned char* output_image_data,
                  int input_w,
                  int input_h,
                  int model_index)
{
    lock.lock();

    if (proc_img_task != nullptr)
    {
        lock.unlock();
        return -1;
    }

    // A Stop that arrived while no task was queued (during a model download, for
    // example) must not abort the run the user starts next.
    g_cancel.store(false);

    remove_alpha_channel(input_image_data, input_w, input_h);

    Task* tsk = new Task();
    tsk->image_id = image_id;
    tsk->input_image_data = input_image_data;
    tsk->output_image_data = output_image_data;
    tsk->input_w = input_w;
    tsk->input_h = input_h;
    tsk->input_channel = 3;
    tsk->model_index = model_index;
    proc_img_task = tsk;

    lock.unlock();
    condition.signal();
    return 0;
}

// Ask the tile loop to stop. Returns immediately; the worker reports PROC_END
// with cost == -2 once it has left the loop. Safe to call with no active task.
void cancel_process()
{
    g_cancel.store(true);
}

}
