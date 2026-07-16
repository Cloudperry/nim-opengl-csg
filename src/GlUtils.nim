import std/[tables, strformat, strutils, options, sequtils, bitops, sugar, macros, math]
import pkg/glm
import ./glad/gl
import Logger

# ======================================== Shader class and compilation error handling ========================================
proc checkErrorAndRaise*(shader: GLuint) =
  var code: GLint
  glGetShaderiv(shader, GL_COMPILE_STATUS, addr code)
  if code.GLboolean == GL_FALSE.GLboolean:
    var length: GLint = 0
    glGetShaderiv(shader, GL_INFO_LOG_LENGTH, addr length)
    var errLog = newString(length.int)
    glGetShaderInfoLog(shader, length, nil, errLog.cstring)
    raise newException(Exception, errLog)

proc checkLinkErrorAndRaise*(program: GLuint) =
  var code: GLint
  glGetProgramiv(program, GL_LINK_STATUS, addr code)
  if code.GLboolean == GL_FALSE.GLboolean:
    var length: GLint = 0
    glGetProgramiv(program, GL_INFO_LOG_LENGTH, addr length)
    var errLog = newString(length.int)
    glGetProgramInfoLog(program, length, nil, errLog.cstring)
    raise newException(Exception, errLog)

proc glShaderSourceStr*(shader: GLuint, count: GLsizei, s: string) =
  # Probably doesn't need a wrapper, converter is enough
  let shaderStr = allocCStringArray([s])
  glShaderSource(shader, count, shaderStr, cast[ptr GLint](nil))

proc glShaderBinaryStr*(count: GLsizei, shaders: ptr GLuint, s: string) =
  # Probably doesn't need a wrapper, converter is enough
  glShaderBinary(
    count,
    shaders,
    GL_SHADER_BINARY_FORMAT_SPIR_V,
    cast[pointer](addr s[0]),
    s.len.GLint,
  )

converter toGlSizeIPtr*(n: int): GLsizeiptr =
  GLsizeiptr(n)

converter toGlSizeI*(n: int): GLsizei =
  GLsizei(n)

converter toGlUint*(n: int): GLuint =
  GLuint(n)

converter toGlInt*(n: int): GLint =
  GLint(n)

converter toCstringArray(s: string): cstringArray {.inline.} =
  let arr = [cstring(s)]
  return cast[cstringArray](addr arr)

converter toIndexBuffer*(indices: seq[int]): seq[GLuint] =
  indices.mapIt(it.GLuint)

type ShaderRef* = ref object
  id*: GLuint

proc initShaderProg*(vertexSrc: string, fragmentSrc: string): ShaderRef =
  result = new ShaderRef

  # Compile shaders
  let vertexShader: GLuint = glCreateShader(GL_VERTEX_SHADER)
  var fragmentShader: GLuint = glCreateShader(GL_FRAGMENT_SHADER)
  glShaderSourceStr(vertexShader, 1, vertexSrc)
  glCompileShader(vertexShader)
  checkErrorAndRaise(vertexShader)
  glShaderSourceStr(fragmentShader, 1, fragmentSrc)
  glCompileShader(fragmentShader)
  checkErrorAndRaise(fragmentShader)

  # Link and clean up
  result.id = glCreateProgram()
  glAttachShader(result.id, vertexShader)
  glAttachShader(result.id, fragmentShader)
  glLinkProgram(result.id)
  checkLinkErrorAndRaise(result.id)
  glDeleteShader(vertexShader)
  glDeleteShader(fragmentShader)

proc initBinShaderProg*(vertexSrc: string, fragmentSrc: string): ShaderRef =
  result = new ShaderRef

  # Compile shaders
  let vertexShader: GLuint = glCreateShader(GL_VERTEX_SHADER)
  var fragmentShader: GLuint = glCreateShader(GL_FRAGMENT_SHADER)
  # glShaderSourceStr(vertexShader, 1, vertexSrc, nil)
  glShaderBinaryStr(1, addr vertexShader, vertexSrc)
  glSpecializeShader(
    vertexShader, "main", 0, cast[ptr GLuint](nil), cast[ptr GLuint](nil)
  )
  checkErrorAndRaise(vertexShader)
  glShaderBinaryStr(1, addr fragmentShader, fragmentSrc)
  glSpecializeShader(
    fragmentShader, "main", 0, cast[ptr GLuint](nil), cast[ptr GLuint](nil)
  )
  checkErrorAndRaise(fragmentShader)

  # Link and clean up
  result.id = glCreateProgram()
  glAttachShader(result.id, vertexShader)
  glAttachShader(result.id, fragmentShader)
  glLinkProgram(result.id)
  checkLinkErrorAndRaise(result.id)
  glDeleteShader(vertexShader)
  glDeleteShader(fragmentShader)

proc use*(s: ShaderRef) =
  glUseProgram(s.id)

template withShader*(s: ShaderRef, body: untyped) =
  s.use()
  body
  glUseProgram(0)

proc cleanup*(s: var ShaderRef) =
  glDeleteProgram(s.id)
  s = nil

proc `=dispose`*(s: var ShaderRef) =
  s.cleanup()

# ======================================== Automatic GPU buffer alignment generator ========================================
const std140Alignment* = collect:
  for (list, align) in [
    # Types aligned to 4 bytes
    (
      @[
        GLfloat.getTypeImpl().repr,
        GLint.getTypeImpl().repr,
        GLuint.getTypeImpl().repr,
        GLboolean.getTypeImpl().repr,
      ],
      4,
    ),
    # Types aligned to 8 bytes
    (
      @[
        Vec2f.getTypeImpl().repr,
        Vec2i.getTypeImpl().repr,
        Vec2ui.getTypeImpl().repr,
        Vec2b.getTypeImpl().repr,
        GLdouble.getTypeImpl().repr,
      ],
      8,
    ),
    # Types aligned to 16 bytes
    (
      @[
        Vec3f.getTypeImpl().repr,
        Vec3i.getTypeImpl().repr,
        Vec3ui.getTypeImpl().repr,
        Vec3b.getTypeImpl().repr,
        Vec4f.getTypeImpl().repr,
        Vec4i.getTypeImpl().repr,
        Vec4ui.getTypeImpl().repr,
        Vec4b.getTypeImpl().repr,
        Mat2f.getTypeImpl().repr,
        Mat3f.getTypeImpl().repr,
        Mat4f.getTypeImpl().repr,
        Mat2d.getTypeImpl().repr,
      ],
      16,
    ),
    # Types aligned to 32 bytes
    (@[Mat3d.getTypeImpl().repr, Mat4d.getTypeImpl().repr], 32),
  ]:
    for t in list:
      {t: align}

type UnknownTypeAlignment* = enum
  RaiseError
  Ignore
  AlignToSize

proc desym(n: NimNode) =
  for i, x in n:
    case x.kind
    of nnkSym:
      n[i] = ident($x)
    else:
      desym(x)

proc elementSize(t: NimNode): int {.compileTime.} =
  ## Get the element size of a typed NimNode representing an array
  let T = t.getType
  if T.kind == nnkBracketExpr and $T[0] in ["array", "seq"]:
    case $T[0]
    of "array":
      result = T[2].getSize()
    of "seq":
      result = T[1].getSize()
    else:
      discard
  else:
    error("elementSize: expected an array type, got " & $T.repr, t)

const dontAlignByType* = initTable[string, int]()

template glVec*() {.pragma.}
template glMat*() {.pragma.}

# TODO: Both of these OpenGL std140/430 object generation macros are horribly broken for any struct that isn't very basic. Fix them
# by making new cleaner macros that insert padding fields into the object (or with plugins when Nim 3.0 comes out?).

macro makeGlObjects*(
    unknownAlignment: static UnknownTypeAlignment = RaiseError,
    alignTable: static Table[string, int] = dontAlignByType,
    body: typed,
): untyped =
  for n in body:
    if n.kind == nnkTypeSection:
      for typeDef in n:
        if typeDef.kind == nnkTypeDef:
          let typeName = $typeDef[0]
          let typeNode = typeDef[2]
          if typeNode.kind == nnkObjectTy:
            when defined(glLayoutGenDbg):
              echo fmt"Found object type `{typeName}`"

            if typeNode[2].kind == nnkRecList:
              let fields = typeNode[2]
              for fieldDefSection in fields:
                if fieldDefSection.kind == nnkIdentDefs:
                  let typeNode = fieldDefSection[^2]
                  var typeImplStr = typeNode.getTypeImpl().repr
                  var alignment = alignTable.getOrDefault(typeImplStr)
                  if alignment == int.default and typeImplStr.startsWith("enum"):
                    # For enums, assume that the user has set correct size to match shader side
                    alignment = typeNode.getSize()
                  if alignment == int.default:
                    case unknownAlignment
                    of Ignore:
                      discard
                    of AlignToSize:
                      let sizeAlignment =
                        if typeNode.kind == nnkSym:
                          typeNode.getSize()
                        else:
                          typeNode.elementSize()
                      if sizeAlignment <= 0:
                        raise newException(
                          Exception,
                          fmt"Failed to pad {typeNode} to size, because Nim doesn't know its size.",
                        )
                      else:
                        alignment = sizeAlignment
                    of RaiseError:
                      raise newException(
                        Exception,
                        fmt"Padding not defined for type {typeImplStr.repr}. " &
                          fmt"Define padding for it in your own alignment table (or add it in {currentSourcePath()}).",
                      )

                  for i in 0 .. fieldDefSection.len - 3:
                    if fieldDefSection[i].kind == nnkPragmaExpr:
                      echo fmt"OpenGL object error: Invalid field `{toStrLit(fieldDefSection[i])}` (with node {fieldDefSection[i].kind})"
                      continue
                    when defined(glLayoutGenDbg):
                      echo fmt"Found field `{fieldDefSection[i]}` that will get aligned to {alignment}"

                    # If alignment is zero, it means that unknownAlignment is set to Ignore and this field doesn't have alignment
                    if alignment in 0 .. int16.high:
                      fieldDefSection[i] = nnkPragmaExpr.newTree(
                        fieldDefSection[i],
                        nnkPragma.newTree(
                          nnkCall.newTree(newIdentNode("align"), newLit(alignment))
                        ),
                      )
                else:
                  echo &"OpenGL object Error: Invalid field {{\n{toStrLit(fieldDefSection)}\n}} (with node {fieldDefSection.kind})"

  result = body # Pass through with pragmas added
  result.desym()
  when defined(glLayoutGenDbg):
    echo &"Generated objects with alignment {{\n{toStrLit(result)}\n\n}}"

const alignToSize* = initTable[int, int]()
const sizeExceptions* = {12: 16}.toTable

macro makeSsbo*(body: typed): untyped =
  for n in body:
    if n.kind == nnkTypeSection:
      for typeDef in n:
        if typeDef.kind == nnkTypeDef:
          let typeName = $typeDef[0]
          let typeNode = typeDef[2]
          if typeNode.kind == nnkObjectTy:
            when defined(glLayoutGenDbg):
              echo fmt"Found object type `{typeName}`"

            if typeNode[2].kind == nnkRecList:
              let fields = typeNode[2]
              # Iterate over field groups (lists of fields with same type)
              for fieldDefSection in fields:
                if fieldDefSection.kind == nnkIdentDefs:
                  var typeNode = fieldDefSection[^2]
                  if typeNode.kind == nnkObjectTy:
                    typeNode = typeNode.getTypeImpl()
                  # Find alignment of this group
                  var alignment = 0
                  if typeNode.kind == nnkSym:
                    alignment = typeNode.getSize()
                  elif typeNode.hasCustomPragma(glVec):
                    alignment = typeNode.getSize()
                  elif typeNode.hasCustomPragma(glMat):
                    alignment = typeNode.elementSize()
                  else:
                    alignment = typeNode.elementSize()

                  let newAlignment = sizeExceptions.getOrDefault(alignment)
                  if newAlignment != int.default:
                    alignment = newAlignment

                  if alignment <= 0:
                    raise newException(
                      Exception,
                      fmt"Failed to align {typeNode} to size, because Nim doesn't know its size.",
                    )

                  # Align all the fields in this group
                  for i in 0 .. fieldDefSection.len - 3:
                    if fieldDefSection[i].kind == nnkPragmaExpr:
                      echo fmt"OpenGL object error: Invalid field `{toStrLit(fieldDefSection[i])}` (with node {fieldDefSection[i].kind})"
                      continue
                    when defined(glLayoutGenDbg):
                      echo fmt"Found field `{fieldDefSection[i]}` that will get aligned to {alignment}"

                    if alignment in 0 .. int16.high:
                      fieldDefSection[i] = nnkPragmaExpr.newTree(
                        fieldDefSection[i],
                        nnkPragma.newTree(
                          nnkCall.newTree(newIdentNode("align"), newLit(alignment))
                        ),
                      )
                else:
                  echo &"OpenGL object Error: Invalid field {{\n{toStrLit(fieldDefSection)}\n}} (with node {fieldDefSection.kind})"

  result = body # Pass through with pragmas added
  result.desym()
  when defined(glLayoutGenDbg):
    echo &"Generated objects with alignment {{\n{toStrLit(result)}\n\n}}"

# ======================================== UBO/SSBO class ========================================
type ShaderDataBufferRef*[T: object | seq[object]] = ref object
  id*: GLuint
  shaderSlots: Table[GLuint, int]
  bufferType, usageHint: GLenum
  currentAllocatedSize: int
  data*: ref T

const supportedBufferTypes = [GL_UNIFORM_BUFFER, GL_SHADER_STORAGE_BUFFER]
const validUsageHints = [
  GL_STREAM_DRAW, GL_STREAM_READ, GL_STREAM_COPY, GL_STATIC_DRAW, GL_STATIC_READ,
  GL_STATIC_COPY, GL_DYNAMIC_DRAW, GL_DYNAMIC_READ, GL_DYNAMIC_COPY,
]

proc validateEnumsOrRaise(bufferType, usageHint: GLenum) =
  if bufferType notin supportedBufferTypes:
    raise newException(
      Exception,
      fmt"Unsupported buffer type {bufferType.uint}. This class is for uniform buffers and shader b buffers only.",
    )
  elif usageHint notin validUsageHints:
    raise newException(
      Exception,
      fmt"Invalid usage hint {usageHint.uint}. Check validUsageHints const for valid usages.",
    )

# TODO: Add a macro that scans the object T for seq fields (and other heap allocated data)? This could make using dynamic
# arrays inside OpenGL buffers easier and safer. The macro should check that heap allocated fields are only at the end
# of the object and keep track of how long the static region in the object is.
proc initShaderDataBuffer*[T](
    targetShader: ShaderRef,
    shaderSlot: int,
    bufferType, usageHint: GLenum,
    data: Option[T] = T.none,
): ShaderDataBufferRef[T] =
  validateEnumsOrRaise(bufferType, usageHint)

  result = new ShaderDataBufferRef[T]
  result.bufferType = bufferType
  result.shaderSlots = initTable[GLuint, int]()
  result.shaderSlots[targetShader.id] = shaderSlot
  result.usageHint = usageHint
  result.data = new T
  result.currentAllocatedSize = sizeof T

  glGenBuffers(1, addr result.id)
  glBindBuffer(bufferType, result.id)
  var dataRef: ptr T = nil
  if data.isSome:
    result.data[] = data.get
    dataRef = addr result.data[]
  glBufferData(bufferType, result.currentAllocatedSize, dataRef, result.usageHint)
  glBindBufferBase(bufferType, shaderSlot, result.id)

# TODO: Add function for associating the UBO with more shaders (for UBOs that get passed between shaders like compute -> vertex/fragment)

proc glBind[T](b: ShaderDataBufferRef[T]) =
  glBindBuffer(b.bufferType, b.id)

proc use*[T](b: ShaderDataBufferRef[T], shader: ShaderRef) =
  b.glBind()
  let slot = b.shaderSlots[shader.id]
  glBindBufferBase(b.bufferType, slot, b.id)

# This shouldn't be used with objects that have seq fields as it only uploads part of the object
proc upload*[T](
    s: ShaderDataBufferRef[T],
    bufferType, usageHint: Option[GLenum] = GLenum.none,
    allocExtraBytes = 0,
) =
  s.glBind()
  let bufferType = if bufferType.isSome: bufferType.get else: s.bufferType
  let usageHint = if usageHint.isSome: usageHint.get else: s.usageHint
  when T is object:
    glBufferData(bufferType, sizeof(T) + allocExtraBytes, addr s.data[], usageHint)
  elif T is seq[object]:
    glBufferData(
      bufferType,
      s.data[].len * sizeof(s.data[0]) + allocExtraBytes,
      addr s.data[0],
      usageHint,
    )

proc uploadRegion*[T](
    b: ShaderDataBufferRef[T], offset, size: int, regionStartPtr: pointer
) =
  b.glBind()
  glBufferSubData(b.bufferType, offset, size, regionStartPtr)

template uploadField*[T](b: ShaderDataBufferRef[T], field: untyped) =
  when b.data.field is seq:
    let seqSize = b.data.field.len * sizeof(b.data.field[0])
    if sizeof(T) + seqSize > b.currentAllocatedSize:
      b.upload(allocExtraBytes = seqSize * 2)
    b.uploadRegion(T.offsetOf(field), seqSize, addr b.data.field[0])
  else:
    b.uploadRegion(T.offsetOf(field), sizeof b.data.field, addr b.data.field)

template setField*[T](b: ShaderDataBufferRef[T], field: untyped, value: typed) =
  b.data.field = value
  b.uploadField(field)

# This only works cleanly when the UBO/SSBO class doesn't have any fields that are meant to be directly set
template `.=`*[T](b: ShaderDataBufferRef[T], field: untyped, value: typed) =
  b.setField(field, value)

proc add*[T1, T2](b: var ShaderDataBufferRef[T1], value: T2) =
  when T1 is object:
    {.fatal: "This proc is only meant for seq UBOs/SSBOs.".}
  else:
    b.data[].add value

proc cleanup*(s: var ShaderDataBufferRef) =
  glDeleteBuffers(1, addr s.id)
  s = nil

proc `=dispose`*(s: var ShaderDataBufferRef) =
  s.cleanup()

# ======================================== VBO class ========================================
type
  InitBuf*[T: object] = tuple[data: seq[T], bufType: GLenum]

  VertexAttrib = tuple[glType: GLenum, count: int, size: int]

  # TODO: Add partial uploads/updates for VBO
  VertexBufferRef*[T: object] = ref object
    id*: GLuint
    bufferType: GLenum
    data: seq[T] # Should probably be ref to avoid copying large buffers?
    vertexAttribs: seq[VertexAttrib]
    typeName: string
    slot: int # VBO binding slot

proc glBind*[T: object](b: VertexBufferRef[T]) =
  glBindBuffer(GL_ARRAY_BUFFER, b.id)

proc upload*[T: object](b: var VertexBufferRef[T], data: seq[T], bufferType: GLenum) =
  b.glBind()
  if data.len > 0:
    b.data = data
    b.bufferType = bufferType
    glBufferData(GL_ARRAY_BUFFER, b.data.len * sizeof T, addr b.data[0], b.bufferType)
  else:
    raise newException(Exception, "Can't upload empty buffer")

# TODO: Add more vector types (ints) and add normalization
proc initVertexBuffer*[T: object](
    initBufOpt: Option[InitBuf[T]] = InitBuf[T].none,
    treatInvalidTypesAsPadding: bool = false,
    fieldOverrides: Option[Table[string, GLenum]] = Table[string, GLenum].none,
): VertexBufferRef[T] =
  result = new VertexBufferRef[T]

  glGenBuffers(1, addr result.id)
  for name, val in fieldPairs(T.default):
    if fieldOverrides.isSome and fieldOverrides.get.hasKey(name):
      result.vertexAttribs.add (fieldOverrides.get[name], 1, val.typeof().sizeof())
        # Is the size here correct?
    else:
      let typeName = $typeof(val)
      result.typeName = typeName

      when typeof(val) is GLbyte:
        result.vertexAttribs.add (cGL_BYTE, 1, val.typeof().sizeof())
      elif typeof(val) is GLubyte:
        result.vertexAttribs.add (GL_UNSIGNED_BYTE, 1, val.typeof().sizeof())
      elif typeof(val) is GLshort:
        result.vertexAttribs.add (cGL_SHORT, 1, val.typeof().sizeof())
      elif typeof(val) is GLushort:
        result.vertexAttribs.add (GL_UNSIGNED_SHORT, 1, val.typeof().sizeof())
      elif typeof(val) is GLint:
        result.vertexAttribs.add (cGL_INT, 1, val.typeof().sizeof())
      elif typeof(val) is GLuint:
        result.vertexAttribs.add (GL_UNSIGNED_INT, 1, val.typeof().sizeof())
      elif typeof(val) is GLhalf:
        result.vertexAttribs.add (GL_HALF_FLOAT, 1, val.typeof().sizeof())
      elif typeof(val) is GLfloat:
        result.vertexAttribs.add (cGL_FLOAT, 1, val.typeof().sizeof())
      elif typeof(val) is GLdouble:
        result.vertexAttribs.add (cGL_DOUBLE, 1, val.typeof().sizeof())
      elif typeof(val) is GLfixed:
        result.vertexAttribs.add (cGL_FIXED, 1, val.typeof().sizeof())
      elif typeof(val) is Vec2f:
        result.vertexAttribs &= (cGL_FLOAT, 2, val.typeof().sizeof())
      elif typeof(val) is Vec2d:
        result.vertexAttribs &= (cGL_DOUBLE, 2, val.typeof().sizeof())
      elif typeof(val) is Vec3f:
        result.vertexAttribs &= (cGL_FLOAT, 3, val.typeof().sizeof())
      elif typeof(val) is Vec3d:
        result.vertexAttribs &= (cGL_DOUBLE, 3, val.typeof().sizeof())
      elif typeof(val) is Vec4f:
        result.vertexAttribs &= (cGL_FLOAT, 4, val.typeof().sizeof())
      elif typeof(val) is Vec4d:
        result.vertexAttribs &= (cGL_DOUBLE, 4, val.typeof().sizeof())
      elif treatInvalidTypesAsPadding:
        result.vertexAttribs &= (GL_DONT_CARE, 1, val.typeof().sizeof())
      else:
        raise newException(Exception, fmt"Invalid type for vertex: {typeName}")

  if initBufOpt.isSome:
    let initBuf = initBufOpt.get
    result.upload(initBuf.data, initBuf.bufType)

const GlIntTypes =
  [cGL_BYTE, GL_UNSIGNED_BYTE, cGL_SHORT, GL_UNSIGNED_SHORT, cGL_int, GL_UNSIGNED_INT]
# Not including double here means that splitting CPU-side doubles to floats on the GPU isn't possible.
# There shouldn't be a good use case for it anyway.
const GlFloatTypes =
  [GL_HALF_FLOAT, cGL_FLOAT, cGL_FIXED, GL_FLOAT_VEC2, GL_FLOAT_VEC3, GL_FLOAT_VEC4]
const GlDoubleTypes = [cGL_DOUBLE, GL_DOUBLE_VEC2, GL_DOUBLE_VEC3, GL_DOUBLE_VEC4]

proc use*[T](b: VertexBufferRef[T]) =
  b.glBind()

  var offset = 0
  for i, attrib in b.vertexAttribs:
    if attrib.glType == GL_DONT_CARE: # Ignore padding
      offset += attrib.size
      continue
    elif attrib.glType in GlFloatTypes:
      glVertexAttribFormat(i, attrib.count, attrib.glType, false, offset)
    elif attrib.glType in GlIntTypes:
      glVertexAttribIFormat(i, attrib.count, attrib.glType, offset)
    elif attrib.glType in GlDoubleTypes:
      glVertexAttribLFormat(i, attrib.count, attrib.glType, offset)

    glVertexAttribBinding(i, b.slot)
    glEnableVertexAttribArray(i)
    offset += attrib.size

  glBindVertexBuffer(b.slot, b.id, 0, offset)
  glBindBuffer(GL_ARRAY_BUFFER, 0) # VBO can be unbound as its now part of the VAO

proc cleanup*[T](b: var VertexBufferRef[T]) =
  glDeleteBuffers(1, addr b.id)
  b = nil

proc `=dispose`*[T](b: var VertexBufferRef[T]) =
  b.cleanup()

type
  InitEBuf* = tuple[data: seq[GLuint], bufType: GLenum]
  ElementBufferRef* = ref object
    id*: GLuint
    indices: seq[GLuint]

proc glBind*(b: ElementBufferRef) =
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, b.id)

proc upload*(b: var ElementBufferRef, indices: seq[GLuint], bufferType: GLenum) =
  b.glBind()
  b.indices = indices
  glBufferData(
    GL_ELEMENT_ARRAY_BUFFER, indices.len * sizeof GLuint, addr b.indices[0], bufferType
  )

proc initElementBuffer*(
    initBufOpt: Option[InitEBuf] = InitEBuf.none
): ElementBufferRef =
  result = new ElementBufferRef
  glGenBuffers(1, addr result.id)

  if initBufOpt.isSome:
    let initBuf = initBufOpt.get
    result.upload(initBuf.data, initBuf.bufType)

proc cleanup*(b: var ElementBufferRef) =
  glDeleteBuffers(1, addr b.id)
  b = nil

proc `=dispose`*(b: var ElementBufferRef) =
  b.cleanup()

# ======================================== VAO class ========================================
type VertexArrayRef* = ref object
  id*: GLuint
  attachedElementBuffer: ElementBufferRef

proc initVertexArray*(): VertexArrayRef =
  result = new VertexArrayRef
  glGenVertexArrays(1, addr result.id)

proc cleanup*(a: var VertexArrayRef) =
  glDeleteVertexArrays(1, addr a.id)
  a = nil

proc `=dispose`*(a: var VertexArrayRef) =
  a.cleanup()

proc isActive*(a: VertexArrayRef): bool =
  var currentVertexArrayIdStore: GLint
  glGetIntegerv(GL_VERTEX_ARRAY_BINDING, addr currentVertexArrayIdStore)
  return a.id == cast[GLuint](currentVertexArrayIdStore)

proc attachElementBuffer*(a: var VertexArrayRef, b: ElementBufferRef) =
  a.attachedElementBuffer = b
  if a.isActive():
    b.glBind()

proc glBind(a: VertexArrayRef) =
  glBindVertexArray(a.id)

proc use*(a: VertexArrayRef) =
  a.glBind()
  if a.attachedElementBuffer != nil:
    a.attachedElementBuffer.glBind()

# ======================================== OpenGL error logging setup ========================================
type LoggerProc* = proc(msg: string) {.closure.}
let defaultLogger = proc(msg: string) {.closure.} =
  echo msg
var logger: proc(msg: string) {.closure.} = defaultLogger

proc setGlDebugLoggerProc*(newLogger: LoggerProc) =
  logger = newLogger

proc glDebugOutput(
    source: GLenum,
    glType: GLenum,
    id: GLuint,
    severity: GLenum,
    length: GLsizei,
    message: ptr GLchar,
    userParam: pointer,
) {.stdcall.} =
  let messageStr = cast[cstring](message)
  # ignore non-significant error/warning codes
  if id in [131169'u32, 131185'u32, 131218'u32, 131204'u32]:
    return

  logger "---------------"
  logger fmt"Debug message ({id}): {messageStr}"

  case source
  of GL_DEBUG_SOURCE_API:
    logger "Source: API"
  of GL_DEBUG_SOURCE_WINDOW_SYSTEM:
    logger "Source: Window System"
  of GL_DEBUG_SOURCE_SHADER_COMPILER:
    logger "Source: Shader Compiler"
  of GL_DEBUG_SOURCE_THIRD_PARTY:
    logger "Source: Third Party"
  of GL_DEBUG_SOURCE_APPLICATION:
    logger "Source: Application"
  of GL_DEBUG_SOURCE_OTHER:
    logger "Source: Other"
  else:
    logger "Source: Unexpected"
    # learnopengl.com didn't have any log output for this

  case glType
  of GL_DEBUG_TYPE_ERROR:
    logger "Type: Error"
  of GL_DEBUG_TYPE_DEPRECATED_BEHAVIOR:
    logger "Type: Deprecated Behaviour"
  of GL_DEBUG_TYPE_UNDEFINED_BEHAVIOR:
    logger "Type: Undefined Behaviour"
  of GL_DEBUG_TYPE_PORTABILITY:
    logger "Type: Portability"
  of GL_DEBUG_TYPE_PERFORMANCE:
    logger "Type: Performance"
  of GL_DEBUG_TYPE_MARKER:
    logger "Type: Marker"
  of GL_DEBUG_TYPE_PUSH_GROUP:
    logger "Type: Push Group"
  of GL_DEBUG_TYPE_POP_GROUP:
    logger "Type: Pop Group"
  of GL_DEBUG_TYPE_OTHER:
    logger "Type: Other"
  else:
    logger "Type: Unexpected"
    # learnopengl.com didn't have any log output for this

  case severity
  of GL_DEBUG_SEVERITY_HIGH:
    logger "Severity: high"
  of GL_DEBUG_SEVERITY_MEDIUM:
    logger "Severity: medium"
  of GL_DEBUG_SEVERITY_LOW:
    logger "Severity: low"
  of GL_DEBUG_SEVERITY_NOTIFICATION:
    logger "Severity: notification"
  else:
    logger "Severity: Unexpected"
    # learnopengl.com didn't have any log output for this

  logger ""

proc setupGlDebugLogging*() =
  var flags: GLint
  glGetIntegerv(GL_CONTEXT_FLAGS, addr flags)
  if bitand(flags, GL_CONTEXT_FLAG_DEBUG_BIT.GLint) != 0:
    glEnable(GL_DEBUG_OUTPUT)
    glEnable(GL_DEBUG_OUTPUT_SYNCHRONOUS)
    glDebugMessageCallback(glDebugOutput, cast[pointer](nil))
    glDebugMessageControl(
      GL_DONT_CARE, GL_DONT_CARE, GL_DONT_CARE, 0, cast[ptr GLuint](nil), true
    ) # This controls filtering of log messages
    logger "OpenGL debug logging activated"
  else:
    raise newException(
      Exception,
      "Couldn't setup debug logging. Maybe you tried to setup debug logging without a debug OpenGL context?",
    )
