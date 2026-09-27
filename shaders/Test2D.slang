struct TestParams {
    float4 colorA;
    float4 colorB;
    float2 center;
    float radius;
    float time;
    float aspectRatio;
};

struct PushConstants {
    TestParams* params;
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

    TestParams* p = push.params;

    // Normalized UV coordinates with aspect correction: center at (0, 0)
    float2 uv = float2(float(threadId.x) / float(width), float(threadId.y) / float(height));
    uv = (uv - 0.5) * 2.0;
    uv.x *= p->aspectRatio;

    // 2D Signed Distance Field of a circle: d = length(uv - center) - radius
    float d = length(uv - p->center) - p->radius;

    // Smooth antialiased boundary using pixel derivative or fixed smoothstep
    float pixelSize = 2.0 / float(height);
    float alpha = 1.0 - smoothstep(0.0, pixelSize * 1.5, d);

    // Gradual color cycle over time
    float t = sin(p->time) * 0.5 + 0.5;
    float4 circleColor = lerp(p->colorA, p->colorB, t);

    // Dark background
    float4 bgColor = float4(0.05, 0.05, 0.08, 1.0);

    float4 finalColor = lerp(bgColor, circleColor, alpha);
    outImage[threadId.xy] = finalColor;
}
