#include "shape_layer.h"

Shape::Shape()
{
    one_blob_only = true;
    support_inplace = false;
}

int Shape::forward(const ncnn::Mat& bottom_blob, ncnn::Mat& top_blob, const ncnn::Option& /*opt*/) const
{
    // ncnn image mat is usually dims=3 with (w, h, c).
    // ONNX Shape for NCHW models expects [N, C, H, W].
    int w = bottom_blob.w;
    int h = bottom_blob.h;
    int c = bottom_blob.c;
    int n = 1;

    if (bottom_blob.dims == 1)
    {
        w = bottom_blob.w;
        h = 1;
        c = 1;
    }
    else if (bottom_blob.dims == 2)
    {
        c = 1;
    }

    top_blob.create(4);
    if (top_blob.empty())
        return -100;

    top_blob[0] = (float)n;
    top_blob[1] = (float)c;
    top_blob[2] = (float)h;
    top_blob[3] = (float)w;
    return 0;
}

DEFINE_LAYER_CREATOR(Shape)
