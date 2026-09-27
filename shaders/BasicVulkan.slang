
struct ColorData {
    float4 color;
};

struct PushConstants {
    uint64_t dataAddress;
};
[[vk::push_constant]] PushConstants push;

[[vk::image_format("rgba8")]]
[[vk::binding(0, 0)]]
RWTexture2D<float4> outImage;

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint3 threadId: SV_DispatchThreadID) {
    uint width, height;
    outImage.GetDimensions(width, height);
    if (threadId.x >= width || threadId.y >= height) return;
    ColorData* ptr = (ColorData*)push.dataAddress;
    outImage[threadId.xy] = ptr->color;
}
