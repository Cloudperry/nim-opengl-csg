// Particle Simulation Compute Shader
// Updates particle positions and colors using BDA pointer.

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

struct SimPushConstants
{
    Particle* particles;
    uint particleCount;
    float deltaTime;
    float time;
    float aspectRatio;
};

[[vk::push_constant]]
SimPushConstants push;

[shader("compute")]
[numthreads(256, 1, 1)]
void computeMain(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint idx = dispatchThreadID.x;
    if (idx >= push.particleCount)
        return;

    Particle p = push.particles[idx];

    // Smooth organic potential flow field (harmonic trigonometric curl field)
    float2 pos = p.position;
    float angle = 6.2831853 * (
        sin(pos.x * 1.5 + push.time * 0.25 + p.seed * 6.28) * 0.35 +
        cos(pos.y * 1.5 - push.time * 0.20 + p.seed * 3.14) * 0.35 +
        sin((pos.x + pos.y) * 2.0 + push.time * 0.15) * 0.30
    );

    float2 targetFlow = float2(cos(angle), sin(angle));

    // Smooth velocity steering towards flow vector
    p.velocity = lerp(p.velocity, targetFlow * p.speed, 0.05);
    p.position += p.velocity * push.deltaTime;

    // Wrap around screen boundaries with margin
    float margin = 0.05;
    float maxX = push.aspectRatio + margin;
    float maxY = 1.0 + margin;

    if (p.position.x > maxX)
        p.position.x = -maxX;
    else if (p.position.x < -maxX)
        p.position.x = maxX;

    if (p.position.y > maxY)
        p.position.y = -maxY;
    else if (p.position.y < -maxY)
        p.position.y = maxY;

    // Smooth non-blinking color progression using cosine palette
    p.life += push.deltaTime * 0.12;
    float t = p.life + p.seed * 2.0;

    // Ethereal cosmic palette (cyan, sapphire, magenta, amber)
    float3 a = float3(0.50, 0.50, 0.50);
    float3 b = float3(0.50, 0.50, 0.50);
    float3 c = float3(1.00, 1.00, 1.00);
    float3 d = float3(0.00, 0.33, 0.67);
    float3 col = a + b * cos(6.2831853 * (c * t + d));

    p.color = float4(col, 0.95);

    push.particles[idx] = p;
}
