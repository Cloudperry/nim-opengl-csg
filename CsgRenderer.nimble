# Package
version = "0.1.0"
author = "Roni"
description = "A computer graphics project in Nim and OpenGL"
srcDir = "src"
binDir = "bin"
namedBin["SdfRenderer"] = "sdf-renderer"
namedBin["SdfRendererCompute"] = "sdf-renderer-compute"
backend = "c"
license = "MIT"

# Dependencies
requires "nim >= 2.2.10"
requires "confutils"
requires "https://github.com/stavenko/nim-glm#47d5f8681f3c462b37e37ebc5e7067fa5cba4d16"
requires "glfw == 3.4.0.5"
