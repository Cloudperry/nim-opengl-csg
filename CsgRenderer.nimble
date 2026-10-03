# Package
version = "0.1.0"
author = "Roni"
description = "A computer graphics project using Nim and Vulkan compute shaders"
srcDir = "src"
binDir = "bin"
namedBin["SdfRenderer"] = "sdf-renderer"
namedBin["GpuStreamSampleApp"] = "vulkan-particles"
backend = "c"
license = "MIT"

# Dependencies
requires "nim >= 2.2.10"
requires "confutils"
requires "jsony"
requires "vmath"
requires "https://github.com/stavenko/nim-glm#47d5f8681f3c462b37e37ebc5e7067fa5cba4d16"
requires "https://github.com/nim-lang/sdl3.git"
requires "https://github.com/treeform/vk14.git"
