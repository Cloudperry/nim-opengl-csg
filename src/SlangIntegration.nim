## Slang Reflection Parser & Nim Type Generator
## Provides explicit shader compilation, reflection parsing, and minimal type generation.

import std/[macros, os, strutils]
import jsony
import Slangc
export Slangc

type
  ShaderMetadata* = object
    workgroupX*, workgroupY*, workgroupZ*: uint32

  ShaderArtifacts* = object
    sourcePath*: string
    spvPath*: string
    reflectionPath*: string
    bytecode*: string
    metadata*: ShaderMetadata

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

proc parseShaderReflection*(jsonStr: string): SlangReflection =
  ## Parses a Slang reflection JSON string into a SlangReflection object.
  result = jsonStr.fromJson(SlangReflection)

proc parseShaderReflectionFile*(reflectionPath: string): SlangReflection =
  ## Reads and parses a Slang reflection JSON file at compile time or runtime.
  staticRead(reflectionPath).parseShaderReflection()

proc parseShaderReflection*(artifacts: ShaderArtifacts): SlangReflection =
  ## Parses reflection data directly from a ShaderArtifacts object.
  parseShaderReflectionFile(artifacts.reflectionPath)

proc findStructType*(refl: SlangReflection, structName: string): SlangType =
  ## Recursively finds a struct definition by name within reflection parameters.
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

proc toNimTypeIdent*(t: SlangType): NimNode =
  ## Maps a SlangType to its corresponding Nim AST type node.
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
    let elem = toNimTypeIdent(t.elementType)
    nnkBracketExpr.newTree(ident("array"), newLit(t.elementCount), elem)
  of "array":
    let elem = toNimTypeIdent(t.elementType)
    nnkBracketExpr.newTree(ident("array"), newLit(t.elementCount), elem)
  of "pointer":
    ident("uint64")
  of "struct":
    ident(t.name)
  of "enum":
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

proc compileSlangShader*(
    slangPath: string,
    entryPoint: string = "computeMain",
    layout: ShaderDataLayout = CLayout,
    stage: ShaderStage = Compute,
    target: TargetFormat = SpirV,
    profile: string = "",
): ShaderArtifacts =
  ## Compiles a Slang shader via Slangc, parses its basic metadata,
  ## and returns a ShaderArtifacts object containing paths, bytecode, and workgroup size.
  let resolvedSlang = resolveShaderPath(slangPath)
  if not fileExists(resolvedSlang):
    raise newException(IOError, "Could not find Slang shader file: '" & slangPath & "' (searched project and repo root)")

  # Invalidate Nim compile cache if shader source changes
  discard staticRead(resolvedSlang)

  let baseName = if resolvedSlang.endsWith(".slang"): resolvedSlang[0 .. ^7] else: resolvedSlang
  let reflPath = baseName & ".reflection.json"

  var opts = initSlangcOptions(
    inFile = resolvedSlang,
    stage = stage,
    entryPoint = entryPoint,
    target = target,
    layout = layout,
    profile = profile,
    reflectionJsonFile = reflPath,
  )
  let cmd = opts.makeSlangCmd()
  let checkCmd = cmd & " && echo __SLANG_OK__"
  let compileRes = staticExec(checkCmd)
  if not compileRes.contains("__SLANG_OK__"):
    raise newException(ValueError, "Slang compilation failed for shader '" & slangPath & "'!\nCommand: " & cmd & "\nOutput:\n" & compileRes)

  if not fileExists(reflPath):
    raise newException(IOError, "Slang reflection JSON file was not generated: " & reflPath)

  let jsonStr = staticRead(reflPath)
  let refl = jsonStr.fromJson(SlangReflection)

  var meta = ShaderMetadata(workgroupX: 1, workgroupY: 1, workgroupZ: 1)
  if refl.entryPoints.len > 0:
    let ep = refl.entryPoints[0]
    let tg = ep.threadGroupSize
    meta.workgroupX = (if tg.len > 0: tg[0] else: 1).uint32
    meta.workgroupY = (if tg.len > 1: tg[1] else: 1).uint32
    meta.workgroupZ = (if tg.len > 2: tg[2] else: 1).uint32

  result = ShaderArtifacts(
    sourcePath: resolvedSlang,
    spvPath: opts.outFile,
    reflectionPath: reflPath,
    bytecode: staticRead(opts.outFile),
    metadata: meta,
  )

proc buildTypeAst*(st: SlangType): NimNode =
  ## Builds a Nim type definition AST (nnkTypeDef) for a Slang struct.
  var recList = nnkRecList.newTree()
  for f in st.fields:
    let fieldIdent = postfix(ident(f.name), "*")
    let fieldType = toNimTypeIdent(f.`type`)
    recList.add(nnkIdentDefs.newTree(fieldIdent, fieldType, newEmptyNode()))
  let objNode = nnkObjectTy.newTree(newEmptyNode(), newEmptyNode(), recList)
  result = nnkTypeDef.newTree(postfix(ident(st.name), "*"), newEmptyNode(), objNode)

proc buildSizeAssertAst*(st: SlangType): NimNode =
  ## Builds a static compile-time size assertion AST for a Slang struct.
  if st.sizes.len > 0 and st.sizes[0].value > 0:
    let expSize = st.sizes[0].value
    let reqIdent = ident(st.name)
    let reqName = st.name
    result = quote do:
      static:
        doAssert sizeof(`reqIdent`) == `expSize`, "Struct size mismatch for " & `reqName` & ": Nim=" & $sizeof(`reqIdent`) & " vs Slang=" & $`expSize`
  else:
    result = newEmptyNode()

macro generateNimObjects*(
    refl: static[SlangReflection],
    structNames: static[openArray[string]],
): untyped =
  ## Minimal macro: takes parsed SlangReflection data and generates matching
  ## Nim object definitions and static sizeof assertions for the specified struct names.
  result = newStmtList()
  var typeSection = nnkTypeSection.newTree()

  for reqName in structNames:
    let st = refl.findStructType(reqName)
    if st == nil:
      error("Struct '" & reqName & "' not found in Slang reflection")
    typeSection.add(buildTypeAst(st))
    let assertNode = buildSizeAssertAst(st)
    if assertNode.kind != nnkEmpty:
      result.add(assertNode)

  result.insert(0, typeSection)
