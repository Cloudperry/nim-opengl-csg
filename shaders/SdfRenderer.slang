import Sdf;
import Lighting;
import SdfTestScenes;

struct SceneUniforms {
  // TODO: Add point lights
  float aspect;
  float3 camPos, camForward, camRight, camUp, bgColor;
  float fov;
  float3 mainLightDirection, mainLightColor, ambientLightColor;
  float specularExponent;
}

// TODO: Add union of N shapes and intersection of N shapes to be more efficient with output slots. These could possibly
// even replace the normal binary op versions. This method is possible to use with basically all commutative SDF ops.
enum SdfInstructionKind {
  // Operations
  AddOp,
  SubOp,
  InterOp,
  XorOp,
  SmoothAddOp,
  SmoothSubOp,
  SmoothInterOp,
  // Shapes
  Sphere,
  Box,
  RoundBox,
  BoxFrame,
  Cone,
  CappedCone,
  HexPrism,
  TriPrism,
  Capsule,
  CappedCylinder,
  RoundedCylinder,
  CutSphere,
  Octahedron,
  Pyramid,
  Triangle,
  Quad,
  Plane
}

struct Material {
  float3 color; // Add alpha channel for transparency and add refractive index?
  float
    metalness; // How reflective is the surface? Controls how much of diffuse/specular lighting the surface will have.
}

#define READ_FLOAT(data, idx) asfloat((data)[idx])

#define READ_FLOAT2(data, idx) float2(asfloat((data)[idx]), asfloat((data)[(idx) + 1]))

#define READ_FLOAT3(data, idx) float3(asfloat((data)[idx]), asfloat((data)[(idx) + 1]), asfloat((data)[(idx) + 2]))

#define WRITE_FLOAT(data, idx, val) (data) [(idx)] = asuint((val))

#define WRITE_FLOAT2(data, idx, val)                                                                                   \
  (data) [(idx)] = asuint((val).x);                                                                                    \
  (data) [(idx) + 1] = asuint((val).y)

#define WRITE_FLOAT3(data, idx, val)                                                                                   \
  (data) [(idx)] = asuint((val).x);                                                                                    \
  (data) [(idx) + 1] = asuint((val).y);                                                                                \
  (data) [(idx) + 2] = asuint((val).z)

struct SdfProgramData {
  Material materialData[256];
}

// For complex CSG trees, this can be increased to at least 20 or 30 without destroying performance.
struct SdfProgramRuntimeData {
  float outputs[10];
  float3 colors[10];
}

[ForceInline]
uint getPackedValue(uint packed, uint start, uint length) {
  uint mask = (1u << length) - 1u;
  return (packed >> start) & mask;
}

struct SdfInstruction {
  uint packedData0;
  // First 8 bits kind: Packed instruction kind enum
  // Next 8 bits runtimeArgsIndex: Index to the temporary runtime outputs array
  // Last 16 bits argsIndex: Index to array that has the input parameters for this SDF program

  uint packedData1;
  // First 8 bits outputIndex: Index to the runtime outputs array where this instruction will put its return value to
  // Next 8 bits materialIndex: Index to the materialData array

  // TODO: Use runtimeArgCount for operations on N shapes at once?
  // Next 8 bits argCount (unused): How many uints starting from argsIndex are parameters for this instruction
  // Last 8 bits runtimeArgCount (unused)

  SdfInstructionKind kind() { return (SdfInstructionKind)getPackedValue(packedData0, 0, 8); }
  uint runtimeArgsI() { return getPackedValue(packedData0, 8, 8); }
  uint argsI() { return getPackedValue(packedData0, 16, 16); }
  uint outputI() { return getPackedValue(packedData1, 0, 8); }
  uint materialI() { return getPackedValue(packedData1, 8, 8); }
  uint argCount() { return getPackedValue(packedData1, 16, 8); }
  uint runtimeArgCount() { return getPackedValue(packedData1, 24, 8); }
}

enum RenderMode { BasicLitScene, ShadowedLitScene, UnlitScene, DebugNormals, DebugStepCounts }

struct DebugSettings {
  RenderMode mode;
}

struct SdfPushParams {
  SceneUniforms*   scene;
  DebugSettings*   debugOpt;
  SdfProgramData*  progData;
  SdfInstruction*  prog;
  PointLight*      pointLights;
  uint*            progArgs;
  uint             lightCount;
  uint             instructionCount;
}

[[vk::push_constant]]
SdfPushParams push;

[[vk::image_format("rgba8")]]
[[vk::binding(0, 0)]]
RWTexture2D<float4> outputImage;

struct FragmentOutput {
  float4 color;
}

// NOTE: Implemented by Gemini and checked using spirv-dis to be optimized out of the final shader
struct ArgReader {
  uint* ptr;
  uint  offset;

  [mutating] float nextFloat() {
    return asfloat(ptr[offset++]);
  }

  [mutating] float2 nextFloat2() {
    float2 v = float2(asfloat(ptr[offset]), asfloat(ptr[offset + 1]));
    offset += 2;
    return v;
  }

  [mutating] float3 nextFloat3() {
    float3 v = float3(asfloat(ptr[offset]), asfloat(ptr[offset + 1]), asfloat(ptr[offset + 2]));
    offset += 3;
    return v;
  }
}

// Operations eval
[ForceInline]
float evalAddOp(SdfInstruction insn, SdfProgramRuntimeData runtimeData) {
  float d1 = runtimeData.outputs[insn.runtimeArgsI()];
  float d2 = runtimeData.outputs[insn.runtimeArgsI() + 1];
  return opUnion(d1, d2);
}

[ForceInline]
float evalSubOp(SdfInstruction insn, SdfProgramRuntimeData runtimeData) {
  float d1 = runtimeData.outputs[insn.runtimeArgsI()];
  float d2 = runtimeData.outputs[insn.runtimeArgsI() + 1];
  return opSubtraction(d1, d2);
}

[ForceInline]
float evalInterOp(SdfInstruction insn, SdfProgramRuntimeData runtimeData) {
  float d1 = runtimeData.outputs[insn.runtimeArgsI()];
  float d2 = runtimeData.outputs[insn.runtimeArgsI() + 1];
  return opIntersection(d1, d2);
}

[ForceInline]
float evalXorOp(SdfInstruction insn, SdfProgramRuntimeData runtimeData) {
  float d1 = runtimeData.outputs[insn.runtimeArgsI()];
  float d2 = runtimeData.outputs[insn.runtimeArgsI() + 1];
  return opXor(d1, d2);
}

[ForceInline]
float evalSmoothAddOp(SdfInstruction insn, SdfProgramRuntimeData runtimeData, inout ArgReader reader) {
  float d1 = runtimeData.outputs[insn.runtimeArgsI()];
  float d2 = runtimeData.outputs[insn.runtimeArgsI() + 1];
  float k = reader.nextFloat();
  return opSmoothUnion(d1, d2, k);
}

[ForceInline]
float evalSmoothSubOp(SdfInstruction insn, SdfProgramRuntimeData runtimeData, inout ArgReader reader) {
  float d1 = runtimeData.outputs[insn.runtimeArgsI()];
  float d2 = runtimeData.outputs[insn.runtimeArgsI() + 1];
  float k = reader.nextFloat();
  return opSmoothSubtraction(d1, d2, k);
}

[ForceInline]
float evalSmoothInterOp(SdfInstruction insn, SdfProgramRuntimeData runtimeData, inout ArgReader reader) {
  float d1 = runtimeData.outputs[insn.runtimeArgsI()];
  float d2 = runtimeData.outputs[insn.runtimeArgsI() + 1];
  float k = reader.nextFloat();
  return opSmoothIntersection(d1, d2, k);
}

// Shapes eval
[ForceInline]
float evalSphere(inout ArgReader reader, float3 rayP) {
  float3 p = reader.nextFloat3();
  float r = reader.nextFloat();
  return sdSphere(rayP - p, r);
}

[ForceInline]
float evalBox(inout ArgReader reader, float3 rayP) {
  float3 p = reader.nextFloat3();
  float3 halfExtent = reader.nextFloat3();
  return sdBox(rayP - p, halfExtent);
}

[ForceInline]
float evalRoundBox(inout ArgReader reader, float3 rayP) {
  float3 p = reader.nextFloat3();
  float3 halfExtent = reader.nextFloat3();
  float r = reader.nextFloat();
  return sdRoundBox(rayP - p, halfExtent, r);
}

[ForceInline]
float evalBoxFrame(inout ArgReader reader, float3 rayP) {
  float3 p = reader.nextFloat3();
  float3 b = reader.nextFloat3();
  float e = reader.nextFloat();
  return sdBoxFrame(rayP - p, b, e);
}

[ForceInline]
float evalCone(inout ArgReader reader, float3 rayP) {
  float3 p = reader.nextFloat3();
  float2 c = reader.nextFloat2();
  float h = reader.nextFloat();
  return sdCone(rayP - p, c, h);
}

[ForceInline]
float evalCappedCone(inout ArgReader reader, float3 rayP) {
  float3 p = reader.nextFloat3();
  float3 a = reader.nextFloat3();
  float3 b = reader.nextFloat3();
  float ra = reader.nextFloat();
  float rb = reader.nextFloat();
  return sdCappedCone(rayP - p, a, b, ra, rb);
}

[ForceInline]
float evalHexPrism(inout ArgReader reader, float3 rayP) {
  float3 p = reader.nextFloat3();
  float2 h = reader.nextFloat2();
  return sdHexPrism(rayP - p, h);
}

[ForceInline]
float evalTriPrism(inout ArgReader reader, float3 rayP) {
  float3 p = reader.nextFloat3();
  float2 h = reader.nextFloat2();
  return sdTriPrism(rayP - p, h);
}

[ForceInline]
float evalCapsule(inout ArgReader reader, float3 rayP) {
  float3 p = reader.nextFloat3();
  float3 a = reader.nextFloat3();
  float3 b = reader.nextFloat3();
  float r = reader.nextFloat();
  return sdCapsule(rayP - p, a, b, r);
}

[ForceInline]
float evalCappedCylinder(inout ArgReader reader, float3 rayP) {
  float3 p = reader.nextFloat3();
  float3 a = reader.nextFloat3();
  float3 b = reader.nextFloat3();
  float r = reader.nextFloat();
  return sdCappedCylinder(rayP - p, a, b, r);
}

[ForceInline]
float evalRoundedCylinder(inout ArgReader reader, float3 rayP) {
  float3 p = reader.nextFloat3();
  float ra = reader.nextFloat();
  float rb = reader.nextFloat();
  float h = reader.nextFloat();
  return sdRoundedCylinder(rayP - p, ra, rb, h);
}

[ForceInline]
float evalCutSphere(inout ArgReader reader, float3 rayP) {
  float3 p = reader.nextFloat3();
  float r = reader.nextFloat();
  float h = reader.nextFloat();
  return sdCutSphere(rayP - p, r, h);
}

[ForceInline]
float evalOctahedron(inout ArgReader reader, float3 rayP) {
  float3 p = reader.nextFloat3();
  float s = reader.nextFloat();
  return sdOctahedron(rayP - p, s);
}

[ForceInline]
float evalPyramid(inout ArgReader reader, float3 rayP) {
  float3 p = reader.nextFloat3();
  float h = reader.nextFloat();
  return sdPyramid(rayP - p, h);
}

[ForceInline]
float evalTriangle(inout ArgReader reader, float3 rayP) {
  float3 p = reader.nextFloat3();
  float3 a = reader.nextFloat3();
  float3 b = reader.nextFloat3();
  float3 c = reader.nextFloat3();
  return udTriangle(rayP - p, a, b, c);
}

[ForceInline]
float evalQuad(inout ArgReader reader, float3 rayP) {
  float3 p = reader.nextFloat3();
  float3 a = reader.nextFloat3();
  float3 b = reader.nextFloat3();
  float3 c = reader.nextFloat3();
  float3 d = reader.nextFloat3();
  return udQuad(rayP - p, a, b, c, d);
}

[ForceInline]
float evalPlane(inout ArgReader reader, float3 rayP) {
  float3 p = reader.nextFloat3();
  float3 n = reader.nextFloat3();
  float h = reader.nextFloat();
  return sdPlane(rayP - p, n, h);
}

struct SdfProgramScene : IColoredFloatSdfScene {
  // Specialization keeps material work out of marching, normals and shadow rays.
  static float evaluate<let withColor : bool>(float3 p, out float3 color) {
    uint insnCount = push.instructionCount;
    SdfProgramRuntimeData runtimeData = { 0 };
    float res = float.maxValue;
    color = float3(1);
    for (uint i = 0; i < insnCount; i++) {
      SdfInstruction insn = push.prog[i];
      ArgReader reader = { push.progArgs, insn.argsI() };

      switch (insn.kind()) {
      case SdfInstructionKind.AddOp:
        res = evalAddOp(insn, runtimeData);
        break;
      case SdfInstructionKind.SubOp:
        res = evalSubOp(insn, runtimeData);
        break;
      case SdfInstructionKind.InterOp:
        res = evalInterOp(insn, runtimeData);
        break;
      case SdfInstructionKind.XorOp:
        res = evalXorOp(insn, runtimeData);
        break;
      case SdfInstructionKind.SmoothAddOp:
        res = evalSmoothAddOp(insn, runtimeData, reader);
        break;
      case SdfInstructionKind.SmoothSubOp:
        res = evalSmoothSubOp(insn, runtimeData, reader);
        break;
      case SdfInstructionKind.SmoothInterOp:
        res = evalSmoothInterOp(insn, runtimeData, reader);
        break;
      case SdfInstructionKind.Sphere:
        res = evalSphere(reader, p);
        break;
      case SdfInstructionKind.Box:
        res = evalBox(reader, p);
        break;
      case SdfInstructionKind.RoundBox:
        res = evalRoundBox(reader, p);
        break;
      case SdfInstructionKind.BoxFrame:
        res = evalBoxFrame(reader, p);
        break;
      case SdfInstructionKind.Cone:
        res = evalCone(reader, p);
        break;
      case SdfInstructionKind.CappedCone:
        res = evalCappedCone(reader, p);
        break;
      case SdfInstructionKind.HexPrism:
        res = evalHexPrism(reader, p);
        break;
      case SdfInstructionKind.TriPrism:
        res = evalTriPrism(reader, p);
        break;
      case SdfInstructionKind.Capsule:
        res = evalCapsule(reader, p);
        break;
      case SdfInstructionKind.CappedCylinder:
        res = evalCappedCylinder(reader, p);
        break;
      case SdfInstructionKind.RoundedCylinder:
        res = evalRoundedCylinder(reader, p);
        break;
      case SdfInstructionKind.CutSphere:
        res = evalCutSphere(reader, p);
        break;
      case SdfInstructionKind.Octahedron:
        res = evalOctahedron(reader, p);
        break;
      case SdfInstructionKind.Pyramid:
        res = evalPyramid(reader, p);
        break;
      case SdfInstructionKind.Triangle:
        res = evalTriangle(reader, p);
        break;
      case SdfInstructionKind.Quad:
        res = evalQuad(reader, p);
        break;
      case SdfInstructionKind.Plane:
        res = evalPlane(reader, p);
        break;
      }

      if (withColor) {
        if (insn.kind() >= SdfInstructionKind.Sphere) {
          color = push.progData.materialData[insn.materialI()].color;
        } else {
          float weight = 0.5;
          uint a = insn.runtimeArgsI();
          uint b = insn.runtimeArgsI() + 1;
          float d1 = runtimeData.outputs[a];
          float d2 = runtimeData.outputs[b];

          switch (insn.kind()) {
          case SdfInstructionKind.AddOp:
            weight = d1 <= d2 ? 1 : 0;
            break;
          case SdfInstructionKind.SubOp:
            weight = -d1 >= d2 ? 1 : 0;
            break;
          case SdfInstructionKind.InterOp:
            weight = d1 >= d2 ? 1 : 0;
            break;
          case SdfInstructionKind.XorOp:
            // Follow the same min/max branches as opXor, including inside overlaps.
            weight = min(d1, d2) >= -max(d1, d2)
              ? (d1 <= d2 ? 1 : 0) : (d1 >= d2 ? 1 : 0);
            break;
          case SdfInstructionKind.SmoothSubOp:
            d2 = -d2;
            // fall through to the smooth minimum used by opSmoothSubtraction
          case SdfInstructionKind.SmoothAddOp: {
            float k = READ_FLOAT(push.progArgs, insn.argsI()) * 4.0;
            weight = saturate(0.5 + (d2 - d1) / (2.0 * k));
            break;
          }
          case SdfInstructionKind.SmoothInterOp: {
            float k = READ_FLOAT(push.progArgs, insn.argsI()) * 4.0;
            weight = saturate(0.5 + (d1 - d2) / (2.0 * k));
            break;
          }
          }
          color = lerp(runtimeData.colors[b], runtimeData.colors[a], weight);
        }
        runtimeData.colors[insn.outputI()] = color;
      }
      runtimeData.outputs[insn.outputI()] = res;
    }

    return res;
  }

  static float sdf(float3 p) {
    float3 unusedColor;
    return evaluate<false>(p, unusedColor);
  }

  static float3 surfaceColor(float3 p) {
    float3 color;
    evaluate<true>(p, color);
    return color;
  }
}

// Fancy numeric normal function from https://iquilezles.org/articles/normalsSDF/
float3 calcNormal<T>(T sceneFn, float3 p)
  where T : IFloatSdfScene {
  const float eps = 4e-5;
  const float2 k = float2(1, -1);
  return normalize(k.xyy * sceneFn.sdf(p + k.xyy * eps) + k.yyx * sceneFn.sdf(p + k.yyx * eps) +
                   k.yxy * sceneFn.sdf(p + k.yxy * eps) + k.xxx * sceneFn.sdf(p + k.xxx * eps));
}

// Slang auto-diff based normal
float3 exactNormal<T>(T sceneFn, in float3 p)
  where T : IDifferentiableFloatSdfScene {
  float3 normal;
  for (uint axis = 0; axis < 3; axis++) {
    DifferentialPair<float3> dp =
      diffPair(float3(p.x, p.y, p.z), float3(axis == 0 ? 1.0 : 0.0, axis == 1 ? 1.0 : 0.0, axis == 2 ? 1.0 : 0.0));
    DifferentialPair<float> dpOut = fwd_diff(sceneFn.sdf)(dp);
    normal[axis] = dpOut.d;
  }

  return normalize(normal);
}

static const int maxSteps = 180;
Optional<float3> sphereTrace<T>(T sceneFn, float3 startPos, float3 rayDir, out float rayDist, out float closestSurface,
                                out uint stepCount, float baseHitEps = 1e-6, float farClipDist = 100)
  where T : IFloatSdfScene {
  const float minHitEps = 1e-4;
  const float maxHitEps = 1e-1;
  // TODO: Dynamic far clip distance based on sceneFn contents?

  rayDist = 0;
  for (stepCount = 0; stepCount < maxSteps && rayDist <= farClipDist; stepCount++) {
    float3 pos = startPos + rayDir * rayDist;
    closestSurface = sceneFn.sdf(pos);
    // Change to bigger epsilon on last step as a last attempt to find an intersection
    float hitEps = stepCount == maxSteps - 1 ? maxHitEps : minHitEps;

    if (closestSurface < hitEps) {
      float3 hitPos = pos + rayDir * closestSurface;
      return hitPos;
    }

    rayDist += closestSurface;
  }

  return none;
}

static const uint secondaryRayMaxSteps = 128;

// Soft shadows using Sebastian Aaltonen's technique from https://iquilezles.org/articles/rmshadows/
float sphereTraceShadow<T>(T sceneFn, float3 startPos, float3 rayDir, float w, out float rayDist,
                              out float closestSurface, out uint stepCount, float farClipDist = 100)
  where T : IFloatSdfScene {
  const float hitEps = 0.005;
  float res = 1;
  rayDist = 0;
  float prevClosestSurface = 1e20;
  for (stepCount = 0; stepCount < secondaryRayMaxSteps && rayDist <= farClipDist; stepCount++) {
    closestSurface = sceneFn.sdf(startPos + rayDir * rayDist);

    if (closestSurface < hitEps)
      return 0;

    float y = closestSurface * closestSurface / (2 * prevClosestSurface);
    float d = sqrt(closestSurface * closestSurface - y * y);
    res = min(res, d / (w * max(0, rayDist - y)));
    prevClosestSurface = closestSurface;
    rayDist += closestSurface;
  }

  return res;
}

void renderScene<T>(T sceneFn, inout FragmentOutput output, float3 rayDirection)
  where T : IColoredFloatSdfScene {
  // Lighting is hardcoded for now

  float rayDist, lastStepLen;
  uint stepCount;
  var rayHit = sphereTrace(sceneFn, push.scene.camPos, rayDirection, rayDist, lastStepLen, stepCount);
  if (rayHit.hasValue) {
    let hitPos = rayHit.value;
    // NOTE: Using doubles to calculate normals could make shimmering normals at edges much rarer
    float3 safePos =
      hitPos - (lastStepLen * rayDirection); // TODO: Try to fix normal artifacts by moving this far enough that the
                                             // normal epsilon won't take any of the samples inside the shape?
    float3 worldNormal = calcNormal(sceneFn, safePos);
    float3 hitColor = sceneFn.surfaceColor(hitPos);

    switch (push.debugOpt.mode) {
    case RenderMode.BasicLitScene: {
      output.color = float4(push.scene.ambientLightColor * hitColor, 1.0);
      float3 dirToLight = -push.scene.mainLightDirection;
      output.color.xyz += lambertDiffuse(dirToLight, worldNormal, push.scene.mainLightColor, hitColor);
      output.color.xyz += blinnPhongSpecular(dirToLight, worldNormal, rayDirection, push.scene.mainLightColor,
                                             hitColor, push.scene.specularExponent);

      uint lightCount = push.lightCount;
      for (uint i = 0; i < lightCount; i++) {
        let pointLight = push.pointLights[i];
        let dirToLight = normalize(pointLight.position - hitPos);
        float3 lightColor = pointLight.getIntensity(hitPos);
        output.color.xyz += lambertDiffuse(dirToLight, worldNormal, lightColor, hitColor);
        output.color.xyz +=
          blinnPhongSpecular(dirToLight, worldNormal, rayDirection, lightColor, hitColor, push.scene.specularExponent);
      }
      return;
    }
    case RenderMode.ShadowedLitScene: {
      const float shadowSoftness = 1.0 / 32.0; // Standard softness parameter (k = 32.0). Smaller is sharper.
      const float secondaryRayNudgeDist =
        0.01; // Normal offset to prevent self-shadowing acne
      float3 ambientColor = push.scene.ambientLightColor * hitColor;
      output.color = float4(ambientColor, 1.0);

      // Directional light
      float3 dirToLight = -push.scene.mainLightDirection;
      let lightContribution = sphereTraceShadow(sceneFn, hitPos + secondaryRayNudgeDist * worldNormal, dirToLight,
                                                shadowSoftness, rayDist, lastStepLen, stepCount);
      float3 diffuseColor = lambertDiffuse(dirToLight, worldNormal, push.scene.mainLightColor, hitColor);
      float3 specularColor = blinnPhongSpecular(dirToLight, worldNormal, rayDirection, push.scene.mainLightColor,
                                                hitColor, push.scene.specularExponent);
      output.color.xyz += lightContribution * (diffuseColor + specularColor);

      // Point lights
      uint lightCount = push.lightCount;
      for (uint i = 0; i < lightCount; i++) {
        let pointLight = push.pointLights[i];
        float3 lightColor = pointLight.getIntensity(hitPos);
        if (length(lightColor) > 0.001) {
          let vecToLight = pointLight.position - hitPos;
          let dirToLight = normalize(vecToLight);
          let lightContribution =
            sphereTraceShadow(sceneFn, hitPos + secondaryRayNudgeDist * worldNormal, dirToLight, shadowSoftness,
                              rayDist, lastStepLen, stepCount, length(vecToLight));
          float3 diffuseColor = lambertDiffuse(dirToLight, worldNormal, lightColor, hitColor);
          float3 specularColor = blinnPhongSpecular(dirToLight, worldNormal, rayDirection, lightColor, hitColor,
                                                    push.scene.specularExponent);
          output.color.xyz += lightContribution * (diffuseColor + specularColor);
        }
      }
      return;
    }
    case RenderMode.UnlitScene:
      output.color = float4(hitColor, 1.0);
      return;
    case RenderMode.DebugNormals:
      output.color = float4(worldNormal, 1.0);
      return;
    case RenderMode.DebugStepCounts:
      float normalizedStepCount = saturate((float)stepCount / maxSteps);
      float3 stepsGradientColor = lerp(float3(0, 1, 0), float3(1, 0, 0), normalizedStepCount);
      output.color = float4(stepsGradientColor, 1);
      return;
    }
  }

  // Set to background color to prevent weird colors for pixels with no hits
  output.color = float4(push.scene.bgColor, 1.0);
}

[ForceInline]
float linearToSrgb(float c) {
  return (c <= 0.0031308) ? (c * 12.92) : (1.055 * pow(max(c, 0.0), 1.0 / 2.4) - 0.055);
}

[ForceInline]
float3 linearToSrgb(float3 c) {
  return float3(linearToSrgb(c.r), linearToSrgb(c.g), linearToSrgb(c.b));
}

// Compute shader variant of the renderer with direct BDA pointers and push constants.
[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint3 threadId: SV_DispatchThreadID) {
  uint width, height;
  outputImage.GetDimensions(width, height);
  if (threadId.x >= width || threadId.y >= height)
    return;

  FragmentOutput output = (FragmentOutput)0;

  float2 fragUv = (float2(threadId.xy) + 0.5) / float2(width, height);
  float2 uvNdc = float2(fragUv.x * 2.0 - 1.0, 1.0 - fragUv.y * 2.0);
  uvNdc.x *= push.scene.aspect;
  float z = 1.0 / tan(radians(push.scene.fov) * 0.5); // Image plane depth
  float3 rayDirection = normalize(push.scene.camForward * z + push.scene.camRight * uvNdc.x + push.scene.camUp * uvNdc.y);

  renderScene(SdfProgramScene(), output, rayDirection);
  float2 noiseCoord = float2(float(threadId.x) + 0.5, float(height - 1 - threadId.y) + 0.5);
  output.color += gradientNoiseWithStrength(noiseCoord, 1.0);

  outputImage[threadId.xy] = float4(linearToSrgb(output.color.rgb), output.color.a);
}
