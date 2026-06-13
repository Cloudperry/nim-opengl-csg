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
# Reproducing tests in the thesis
- Instructions to reproduce the tests in Fig. 4.3 can be found [here](https://github.com/Cloudperry/nim-opengl-csg/tree/sphere-tracing-inconsistent-perf)
- Instructions to reproduce the shader compilation test at the start of section 4.3 can be found [here](https://github.com/Cloudperry/nim-opengl-csg/tree/sphere-tracing-hardcoded-scene-reload-time)
- Instructions to reproduce the interpreter overhead test related to Fig. 4.5 can be found in [here](https://github.com/Cloudperry/nim-opengl-csg/tree/sphere-tracing-dynamic-scene-perfloss)
- All the benchmarks described in the linked branches output their results in the terminal
