## Slang Reflection Parser & Macro Codegen
## Compiles Slang shaders via Slangc at compile-time and generates matching Nim types and metadata.

import std/[macros, os, strutils]
import jsony
import Slangc
export Slangc

type
  SlangSize* = object
    kind*: string
    value*: int
    alignment*: int

  SlangBinding* = object
    kind*: string
    offset*: int
    size*: int
    index*: int
    elementStride*: int

  SlangType* = ref object
    kind*: string
    name*: string
    scalarType*: string
    elementCount*: int
    elementType*: SlangType
    valueType*: SlangType
    fields*: seq[SlangField]
    sizes*: seq[SlangSize]

  SlangField* = object
    name*: string
    `type`*: SlangType
    binding*: SlangBinding

  SlangParameter* = object
    name*: string
    binding*: SlangBinding
    format*: string
    `type`*: SlangType

  SlangEntryPoint* = object
    name*: string
    stage*: string
    threadGroupSize*: seq[int]

  SlangReflection* = object
    version*: string
    parameters*: seq[SlangParameter]
    entryPoints*: seq[SlangEntryPoint]

proc parseSlangReflectionJson*(jsonStr: string): SlangReflection =
  result = jsonStr.fromJson(SlangReflection)

proc findStructType*(refl: SlangReflection, structName: string): SlangType =
  proc search(t: SlangType): SlangType =
    if t == nil: return nil
    if t.kind == "struct" and t.name == structName:
      return t
    if t.elementType != nil:
      let found = search(t.elementType)
      if found != nil: return found
    if t.valueType != nil:
      let found = search(t.valueType)
      if found != nil: return found
    for f in t.fields:
      let found = search(f.`type`)
      if found != nil: return found
    return nil

  for p in refl.parameters:
    let found = search(p.`type`)
    if found != nil: return found
  return nil

proc toNimTypeIdent(t: SlangType): NimNode =
  case t.kind
  of "scalar":
    case t.scalarType
    of "float32": ident("float32")
    of "float64": ident("float64")
    of "uint32": ident("uint32")
    of "int32": ident("int32")
    of "uint64": ident("uint64")
    of "int64": ident("int64")
    of "uint8": ident("uint8")
    of "int8": ident("int8")
    of "bool": ident("bool")
    else: ident("uint32")
  of "vector":
    # Vector of scalars e.g. float4 -> array[4, float32]
    let elem = toNimTypeIdent(t.elementType)
    nnkBracketExpr.newTree(ident("array"), newLit(t.elementCount), elem)
  of "array":
    let elem = toNimTypeIdent(t.elementType)
    nnkBracketExpr.newTree(ident("array"), newLit(t.elementCount), elem)
  of "pointer":
    # 64-bit Buffer Device Address pointer
    ident("uint64")
  of "struct":
    ident(t.name)
  of "enum":
    # Slang enums are 32-bit unsigned integers
    ident("uint32")
  else:
    ident("uint64")

proc resolveShaderPath*(path: string): string =
  ## Resolves a shader path to an absolute path, searching common source locations at compile time.
  if isAbsolute(path) and fileExists(path):
    return path
  let projPath = getProjectPath()
  if fileExists(projPath / path):
    return (projPath / path).normalizedPath
  if fileExists(projPath.parentDir / path):
    return (projPath.parentDir / path).normalizedPath
  let repoRoot = currentSourcePath.parentDir.parentDir
  if fileExists(repoRoot / path):
    return (repoRoot / path).normalizedPath
  return path

macro importAndCompileShader*(
    slangPath: static[string],
    typesToImport: static[openArray[string]],
    stage: static[ShaderStage] = Compute,
    entryPoint: static[string] = "computeMain",
    layout: static[ShaderDataLayout] = CLayout,
    target: static[TargetFormat] = SpirV,
    profile: static[string] = "",
    useEntrypointName: static[bool] = false,
): untyped =
  ## Compiles the Slang shader via Slangc at compile-time with the requested layout,
  ## tracks file dependencies, parses reflection JSON, and emits matching Nim types.
  let resolvedSlang = resolveShaderPath(slangPath)
  if not fileExists(resolvedSlang):
    error("Could not find Slang shader file: '" & slangPath & "' (searched project and repo root)")

  # Track shader source file as compile-time dependency for cache invalidation
  discard staticRead(resolvedSlang)

  let (_, shaderBaseName, _) = splitFile(resolvedSlang)
  let baseName = if resolvedSlang.endsWith(".slang"): resolvedSlang[0 .. ^7] else: resolvedSlang
  let reflPath = baseName & ".reflection.json"

  var opts = initSlangcOptions(
    inFile = resolvedSlang,
    stage = stage,
    entryPoint = entryPoint,
    target = target,
    layout = layout,
    profile = profile,
    useEntrypointName = useEntrypointName,
    reflectionJsonFile = reflPath,
  )
  let cmd = opts.makeSlangCmd()
  let checkCmd = cmd & " && echo __SLANG_OK__"
  let compileRes = staticExec(checkCmd)
  if not compileRes.contains("__SLANG_OK__"):
    error("Slang compilation failed for shader '" & slangPath & "'!\nCommand: " & cmd & "\nOutput:\n" & compileRes)

  # Check and read reflection file
  if not fileExists(reflPath):
    error("Slang reflection JSON file was not generated: " & reflPath)
  let jsonStr = staticRead(reflPath)
  let refl = parseSlangReflectionJson(jsonStr)

  result = newStmtList()
  var typeSection = nnkTypeSection.newTree()

  for reqName in typesToImport:
    let st = refl.findStructType(reqName)
    if st == nil:
      error("Struct '" & reqName & "' not found in Slang reflection JSON: " & reflPath)

    # Standard Nim object type, matching C ABI under CLayout / Scalar layout
    var recList = nnkRecList.newTree()
    for f in st.fields:
      let fieldIdent = postfix(ident(f.name), "*")
      let fieldType = toNimTypeIdent(f.`type`)
      recList.add(nnkIdentDefs.newTree(fieldIdent, fieldType, newEmptyNode()))

    var objNode = nnkObjectTy.newTree(newEmptyNode(), newEmptyNode(), recList)
    var typeDef = nnkTypeDef.newTree(postfix(ident(reqName), "*"), newEmptyNode(), objNode)
    typeSection.add(typeDef)

  result.add(typeSection)

  # Static size assertions for strict ABI validation
  for reqName in typesToImport:
    let st = refl.findStructType(reqName)
    if st != nil and st.sizes.len > 0 and st.sizes[0].value > 0:
      let expSize = st.sizes[0].value
      let reqIdent = ident(reqName)
      let assertStmt = quote do:
        static:
          doAssert sizeof(`reqIdent`) == `expSize`, "Struct size mismatch for " & `reqName` & ": Nim=" & $sizeof(`reqIdent`) & " vs Slang=" & $`expSize`
      result.add(assertStmt)

  # Generate workgroup and metadata helpers (named by shaderBaseName to allow multiple shader imports per module)
  if refl.entryPoints.len > 0:
    let ep = refl.entryPoints[0]
    let tg = ep.threadGroupSize
    let tgX = if tg.len > 0: tg[0] else: 1
    let tgY = if tg.len > 1: tg[1] else: 1
    let tgZ = if tg.len > 2: tg[2] else: 1

    let metaIdentShader = ident("getShaderMeta_" & shaderBaseName)
    let metaProcShader = quote do:
      proc `metaIdentShader`*(): tuple[workgroupX, workgroupY, workgroupZ: uint32] =
        (`tgX`.uint32, `tgY`.uint32, `tgZ`.uint32)
    result.add(metaProcShader)

    if useEntrypointName:
      let metaIdentEp = ident("getShaderMeta_" & ep.name)
      let metaProcEp = quote do:
        proc `metaIdentEp`*(): tuple[workgroupX, workgroupY, workgroupZ: uint32] =
          (`tgX`.uint32, `tgY`.uint32, `tgZ`.uint32)
      result.add(metaProcEp)

  # Path helpers
  let spvPathLit = opts.outFile
  let pathProcShader = ident("getShaderBinaryPath_" & shaderBaseName)
  let pathProc = quote do:
    proc `pathProcShader`*(): string = `spvPathLit`
  result.add(pathProc)

  # Compiled bytecode embedded at compile-time
  let spvBytes = staticRead(opts.outFile)
  let codeProcShader = ident("getShaderCode_" & shaderBaseName)
  let codeProc = quote do:
    proc `codeProcShader`*(): string = `spvBytes`
  result.add(codeProc)

  if useEntrypointName:
    let codeProcEp = ident("getShaderCode_" & entryPoint)
    let codeProcEpStmt = quote do:
      proc `codeProcEp`*(): string = `spvBytes`
    result.add(codeProcEpStmt)

    let pathProcEp = ident("getShaderBinaryPath_" & entryPoint)
    let pathProcEpStmt = quote do:
      proc `pathProcEp`*(): string = `spvPathLit`
    result.add(pathProcEpStmt)

template importSlangShader*(
    slangPath: static[string],
    typesToImport: static[openArray[string]],
    stage: static[ShaderStage] = Compute,
    entryPoint: static[string] = "computeMain",
    layout: static[ShaderDataLayout] = CLayout,
    target: static[TargetFormat] = SpirV,
    profile: static[string] = "",
    useEntrypointName: static[bool] = false,
): untyped =
  importAndCompileShader(slangPath, typesToImport, stage, entryPoint, layout, target, profile, useEntrypointName)
