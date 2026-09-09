# System requirements
- OpenGL 4.6 capable GPU (tested only on Linux Mesa drivers, NVIDIA drivers might work too)
# Downloading dependencies (Linux)
1. Download the Slang shader compiler from [here](https://github.com/shader-slang/slang/releases/tag/v2025.18.2) and extract it somewhere
2. Install GLFW 3 for your Linux distribution (the package name is usually glfw or glfw3)
# Compiling the project and downloading dependencies (Linux)
1. Install the Nim compiler using [these instructions](https://github.com/nim-lang/choosenim#installation)
2. Clone the project repository
3. Execute `nimble build` in the project directory
4. After Nimble has built the project, the binary should be in the `bin/` folder inside the project directory
# Running the sphere tracer
Run either `bin/sdf-renderer` or `bin/sdf-renderer-compute` with
`--slangBinPath=/path/to/Slang/bin`. Both render the same animated SDF bytecode scene.
Use F1 for lighting, F2 for shadows, F3 for unlit material colors, F5 for normals,
and F6 for marching step counts.
The initial mode can also be selected with `--renderMode=UnlitScene` (or
`BasicLitScene`, `ShadowedLitScene`, `DebugNormals`, `DebugStepCounts`).

## SDF colors
Register linear RGB colors with `SceneBuilder.addMaterial`, then select a material
with `useMaterial` before adding primitives:

```nim
let leafGreen = builder.addMaterial(vec3f(0.075, 0.36, 0.045))
builder.useMaterial(leafGreen)
let ball = builder.addSphere(vec3f(0), 2)
```

The selected material applies to all subsequent primitives until changed. Material
zero is white for compatibility with scenes that do not specify colors; the table
holds up to 256 materials including that default. Colors are stored in the material
SSBO and each primitive's bytecode stores its material index.

Hard CSG operations keep the color of the operand that determines the surface
(including the cutter on exposed subtraction surfaces). Smooth operations blend
colors using the same distance-based weighting as their smoothing curve. Material
evaluation runs only at primary-ray hits, not during distance marching or shadows.
The default room uses warm limestone-colored walls and earthy sandstone surfaces
with a leafy green moving sphere.
Run the material bytecode regression tests with
`nimble c -r --path:src tests/testSdfMaterials.nim`.

# Reproducing tests in the thesis
- Instructions to reproduce the tests in Fig. 4.3 can be found [here](https://github.com/Cloudperry/nim-opengl-csg/tree/sphere-tracing-inconsistent-perf)
- Instructions to reproduce the shader compilation test at the start of section 4.3 can be found [here](https://github.com/Cloudperry/nim-opengl-csg/tree/sphere-tracing-hardcoded-scene-reload-time)
- Instructions to reproduce the interpreter overhead test related to Fig. 4.5 can be found in [here](https://github.com/Cloudperry/nim-opengl-csg/tree/sphere-tracing-dynamic-scene-perfloss)
- All the benchmarks described in the linked branches output their results in the terminal
