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

// Smooth sunset color palette: continuous gradient from warm orange/amber to deep twilight blue
float3 sunsetPalette(float s)
{
    // s in [0, 1]: 0.0 = deep twilight blue, 1.0 = warm sunset amber
    float3 deepBlue    = float3(0.08, 0.22, 0.65);  // dusk twilight blue
    float3 duskViolet  = float3(0.48, 0.20, 0.58);  // evening violet / twilight purple
    float3 sunsetCoral = float3(0.95, 0.38, 0.20);  // vibrant sunset coral
    float3 sunsetAmber = float3(1.00, 0.68, 0.15);  // warm golden amber

    float t = clamp(s, 0.0, 1.0);
    if (t < 0.33)
    {
        float k = t / 0.33;
        return lerp(deepBlue, duskViolet, smoothstep(0.0, 1.0, k));
    }
    else if (t < 0.66)
    {
        float k = (t - 0.33) / 0.33;
        return lerp(duskViolet, sunsetCoral, smoothstep(0.0, 1.0, k));
    }
    else
    {
        float k = (t - 0.66) / 0.34;
        return lerp(sunsetCoral, sunsetAmber, smoothstep(0.0, 1.0, k));
    }
}

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

    // Sunset gradient progression: vertical position bias + smooth harmonic time shift
    p.life += push.deltaTime * 0.15;
    float verticalBias = 1.0 - (p.position.y * 0.5 + 0.5);
    float timeShift = sin(p.life * 0.5 + p.seed * 6.2831853) * 0.22;
    float sunsetFactor = clamp(verticalBias * 0.70 + 0.15 + timeShift, 0.0, 1.0);

    float3 col = sunsetPalette(sunsetFactor);
    p.color = float4(col, 0.95);

    push.particles[idx] = p;
}
