# TODO: Add DAG-style scene graph like representation for SDF scenes here.
# Basic AST would be simpler, but scene graph allows for instancing. Instancing on its own
# doesn't have any clear render perf benefits since the SDFs need to be evaluated again for
# different positions, but it makes the scene representation more compact and could enable
# some use cases or better codegen in the future.
