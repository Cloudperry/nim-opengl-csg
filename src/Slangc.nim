import std/[os, osproc, strformat, strutils]

type
  ShaderStage* = enum
    Fragment = "fragment"
    Vertex = "vertex"
    Compute = "compute"

  TargetFormat* = enum
    Glsl = "glsl"
    SpirV = "spirv"

  ShaderDataLayout* = enum
    Default = ""                       ## Default slangc layout rules
    Scalar = "-fvk-use-scalar-layout"  ## Vulkan/GLSL scalar block layout
    CLayout = "-fvk-use-c-layout"      ## C/C++ structure layout rules for SPIR-V
    DxLayout = "-fvk-use-dx-layout"    ## FXC member packing rules
    GlLayout = "-fvk-use-gl-layout"    ## std430 layout for raw buffer load/stores

  ## Options for invoking the slangc shader compiler on a single shader file/stage.
  SlangcOptions* = object
    inFile*, entryPoint*, outFile*: string
    target*: TargetFormat = Glsl
    stage*: ShaderStage
    layout*: ShaderDataLayout = Default
    profile*: string = ""               ## Optional profile override (e.g. "glsl_460", "spirv_1_5")
    useEntrypointName*: bool = false    ## If true, passes -fvk-use-entrypoint-name so SPIR-V retains source entry name
    reflectionJsonFile*: string = ""    ## If non-empty, passes -reflection-json <path>

proc fileExt(t: TargetFormat): string =
  case t
  of Glsl: "glsl"
  of SpirV: "spv"

proc short(s: ShaderStage): string =
  case s
  of Fragment: "Frag"
  of Vertex: "Vert"
  of Compute: "Comp"

proc getOutputFilename*(o: SlangcOptions): string =
  let inputName = o.inFile.split(".")
  return fmt"{inputName[0]}{o.stage.short()}.{o.target.fileExt()}"

proc updateOutputFilename(o: var SlangcOptions) =
  o.outFile = o.getOutputFilename()

proc getEntryPoint*(stage: ShaderStage): string =
  fmt"{stage}Main"

proc initSlangcOptions*(
    inFile: string,
    stage: ShaderStage,
    entryPoint = getEntryPoint(stage),
    target = SlangcOptions.default.target,
    layout = Default,
    profile = "",
    useEntrypointName = false,
    reflectionJsonFile = "",
): SlangcOptions =
  result =
    SlangcOptions(
      inFile: inFile,
      entryPoint: entryPoint,
      target: target,
      stage: stage,
      layout: layout,
      profile: profile,
      useEntrypointName: useEntrypointName,
      reflectionJsonFile: reflectionJsonFile,
    )
  result.updateOutputFilename()

proc `inFile=`*(o: var SlangcOptions, path: string) =
  o.inFile = path
  o.updateOutputFilename()

proc `target=`*(o: var SlangcOptions, target: TargetFormat) =
  o.target = target
  o.updateOutputFilename()

proc `stage=`*(o: var SlangcOptions, s: ShaderStage) =
  o.stage = s
  o.updateOutputFilename()

proc `layout=`*(o: var SlangcOptions, l: ShaderDataLayout) =
  o.layout = l

proc `profile=`*(o: var SlangcOptions, p: string) =
  o.profile = p

proc `useEntrypointName=`*(o: var SlangcOptions, v: bool) =
  o.useEntrypointName = v

proc `reflectionJsonFile=`*(o: var SlangcOptions, path: string) =
  o.reflectionJsonFile = path

proc makeSlangCmd*(o: SlangcOptions, slangPath = ""): string =
  let slangBin =
    if slangPath.len > 0:
      slangPath / "slangc"
    else:
      "slangc"

  let entryPointOptArg =
    if o.entryPoint.len > 0:
      fmt" -entry {o.entryPoint}"
    else:
      ""

  let layoutOptArg =
    if ($o.layout).len > 0:
      fmt" {$o.layout}"
    else:
      ""

  # Profile handling:
  # If specified explicitly, use it. Otherwise, default to glsl_460 for GLSL target,
  # but omit -profile for SPIR-V so Vulkan gets standard SPIR-V without OpenGL-isms.
  let profileOptArg =
    if o.profile.len > 0:
      fmt" -profile {o.profile}"
    elif o.target == Glsl:
      " -profile glsl_460"
    else:
      ""

  let entryNameOptArg =
    if o.useEntrypointName:
      " -fvk-use-entrypoint-name"
    else:
      ""

  let reflOptArg =
    if o.reflectionJsonFile.len > 0:
      fmt" -reflection-json {o.reflectionJsonFile}"
    else:
      ""

  return
    fmt"{slangBin} {o.inFile} -no-mangle -target {o.target} -stage {o.stage}{entryPointOptArg}{profileOptArg}{layoutOptArg}{entryNameOptArg}{reflOptArg} -o {o.outFile}"

proc compileShaderOrRaise*(o: SlangcOptions, slangPath = ""): string =
  ## Runs slangc and returns the compiled shader source or bytes, raising on failure.
  let cmd = o.makeSlangCmd(slangPath)
  let cmdRes = cmd.execCmdEx()
  if cmdRes.exitCode != 0:
    raise newException(
      Exception, fmt"Failed to compile shader {o.inFile} (command: {cmd}):\n\n{cmdRes.output}"
    )

  return o.outFile.readFile()

if isMainModule:
  let vertOpts = initSlangcOptions(
    stage = Vertex, inFile = "shaders/HelloTriangle.slang", target = Glsl
  )
  echo compileShaderOrRaise(vertOpts)
  let fragOpts = initSlangcOptions(
    stage = Fragment, inFile = "shaders/HelloTriangle.slang", target = Glsl
  )
  echo compileShaderOrRaise(fragOpts)
