// Particle Rasterization / Rendering Compute Shader
// Renders dot particles from BDA buffer to storage image.

struct Particle
{
    float2 position;
    float2 velocity;
    float4 color;
    float life;
    float size;
    float speed;
    float seed;
};

struct RenderPushConstants
{
    Particle* particles;
    uint particleCount;
    uint screenWidth;
    uint screenHeight;
    float aspectRatio;
};

[[vk::binding(0, 0)]]
WTexture2D<float4> targetImage;

[[vk::push_constant]]
RenderPushConstants push;

[shader("compute")]
[numthreads(256, 1, 1)]
void computeMain(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint idx = dispatchThreadID.x;
    if (idx >= push.particleCount)
        return;

    Particle p = push.particles[idx];

    // Map [-aspectRatio, aspectRatio] x [-1, 1] to pixel coordinates [0, width) x [0, height)
    float u = (p.position.x / push.aspectRatio) * 0.5 + 0.5;
    float v = p.position.y * 0.5 + 0.5;

    int cx = int(u * float(push.screenWidth));
    int cy = int(v * float(push.screenHeight));

    if (cx < 0 || cx >= int(push.screenWidth) || cy < 0 || cy >= int(push.screenHeight))
        return;

    int r = int(ceil(p.size));
    float r2 = p.size * p.size;

    for (int dy = -r; dy <= r; ++dy)
    {
        int py = cy + dy;
        if (py < 0 || py >= int(push.screenHeight))
            continue;

        for (int dx = -r; dx <= r; ++dx)
        {
            int px = cx + dx;
            if (px < 0 || px >= int(push.screenWidth))
                continue;

            float d2 = float(dx * dx + dy * dy);
            if (d2 <= r2)
            {
                float falloff = 1.0 - sqrt(d2) / (p.size + 0.2);
                float4 col = float4(p.color.rgb, p.color.a * falloff);
                targetImage.Store(int2(px, py), col);
            }
        }
    }
}
