#ifndef SHAPE_LAYER_H
#define SHAPE_LAYER_H

#include "layer.h"

// Minimal ONNX Shape op for poorly converted models (e.g. HF realesrgan-x2plus).
// Emits NCHW dims as a 1-D float vector: [n, c, h, w].
class Shape : public ncnn::Layer
{
public:
    Shape();
    virtual int forward(const ncnn::Mat& bottom_blob, ncnn::Mat& top_blob, const ncnn::Option& opt) const;
};

::ncnn::Layer* Shape_layer_creator(void* userdata);

#endif // SHAPE_LAYER_H
