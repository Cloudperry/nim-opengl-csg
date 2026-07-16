import std/[os, osproc, strformat, strutils]

type
  ShaderStage* = enum
    Fragment = "fragment"
    Vertex = "vertex"
    Compute = "compute"

  TargetFormat* = enum
    Glsl = "glsl"
    SpirV = "spirv"

  ## Options for invoking the slangc shader compiler on a single shader file/stage.
  SlangcOptions* = object
    inFile*, entryPoint*, outFile*: string
    target*: TargetFormat = Glsl
    stage*: ShaderStage

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
): SlangcOptions =
  result =
    SlangcOptions(inFile: inFile, entryPoint: entryPoint, target: target, stage: stage)
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

proc makeSlangCmd(o: SlangcOptions, slangPath = ""): string =
  let slangBin =
    if slangPath.len > 0:
      slangPath / "slangc"
    else:
      findExe("slangc")
  if slangBin.len == 0:
    raise newException(Exception, "Failed to find slangc in PATH")

  let entryPointOptArg =
    if o.entryPoint.len > 0:
      fmt" -entry {o.entryPoint}"
    else:
      ""
  return
    fmt"{slangBin} {o.inFile} -no-mangle -target {o.target} -stage {o.stage}{entryPointOptArg} -profile glsl_460 -o {o.outFile}"

proc compileShaderOrRaise*(o: SlangcOptions, slangPath = ""): string =
  ## Runs slangc and returns the compiled shader source, raising with the compiler output
  ## on failure.
  let cmdRes = o.makeSlangCmd(slangPath).execCmdEx()
  if cmdRes.exitCode != 0:
    raise newException(
      Exception, &"Failed to compile shader {o.inFile}:\n\n{cmdRes.output}"
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
