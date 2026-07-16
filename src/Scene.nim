import std/[strformat, options]
import ./glad/gl
import pkg/glm
import GlUtils

# ======================================== Camera handling and basic transforms ========================================
const degToRad = PI / 180

type
  Transform* = object
    pos*: Vec3f
    scale*: Vec3f = vec3f(1.0, 1.0, 1.0)
    rotation*: Vec3f

  ProjectionKind* = enum
    Orthographic
    Perspective

  FpCameraOptions* = object
    # Pitch/yaw scaling to match Source engine. In this engine,
    # transforms use radian rotations so Source engine constants need to be scaled.
    pitchScale*: float = 0.022 * degToRad
    yawScale*: float = 0.022 * degToRad
    sensitivity*: float = 2
    moveSpeed*: float = 3

  # TODO: Focal length sensitivity scaling for intuitive feeling sensitivity while scoping/changing FOV
  RasterizedCamera* = object
    pos*: Vec3f
    # Positive yaw means turning left and positive pitch means turning up
    yaw*: GLfloat = 0 # Start the camera looking forward (toward -Z)
    pitch*: GLfloat = 0
    viewMat*, projectionMat*: Mat4f
    aspectRatio*, nearClip*, farClip*: GLfloat
    # Quick hack for updating matrices only when they are needed by the rasterizer. Think about it later,
    # if the camera class should be split for ray tracing and rasterization.
    rasterizerOn*: bool
    forward*: Vec3f = vec3f(0, 0, -1)
    right*: Vec3f = vec3f(1, 0, 0)
    up*: Vec3f = vec3f(0, 1, 0)
    case kind*: ProjectionKind
    of Orthographic:
      frustumLength*: GLfloat
    of Perspective:
      verticalFov*: GLfloat

proc perspectiveRH*[T](fovy, aspect, zNear, zFar: T): Mat4[T] =
  let tanHalfFovy = tan(fovy / T(2))
  result = mat4[T](0.0)
  result[0, 0] = -T(1) / (aspect * tanHalfFovy)
  result[1, 1] = -T(1) / (tanHalfFovy)
  result[2, 3] = T(-1)

  result[2, 2] = -(zFar + zNear) / (zFar - zNear)
  result[3, 2] = -(T(2) * zFar * zNear) / (zFar - zNear)

proc updateProjectionMat*(c: var RasterizedCamera) =
  if c.rasterizerOn:
    case c.kind
    of Orthographic:
      let (frustumW, frustumH) = (c.frustumLength * c.aspectRatio, c.frustumLength)
      c.projectionMat = ortho[GLfloat](
        -frustumW / 2, frustumW / 2, -frustumH / 2, frustumH / 2, c.nearClip, c.farClip
      )
    of Perspective:
      c.projectionMat =
        perspectiveRH[GLfloat](c.verticalFov, c.aspectRatio, c.nearClip, c.farClip)

proc initPerspectiveCamera*(
    verticalFov, aspectRatio, nearClip, farClip: GLfloat, rasterizerOn: bool
): RasterizedCamera =
  result = RasterizedCamera(
    kind: Perspective,
    aspectRatio: aspectRatio,
    verticalFov: verticalFov,
    nearClip: nearClip,
    farClip: farClip,
    rasterizerOn: rasterizerOn,
  )
  result.updateProjectionMat()

proc setPerspective*(
    c: var RasterizedCamera, verticalFov, aspectRatio, nearClip, farClip: GLfloat
) =
  c.kind = Perspective
  c.verticalFov = verticalFov
  c.aspectRatio = aspectRatio
  c.nearClip = nearClip
  c.farClip = farClip
  c.updateProjectionMat()

proc initOrthographicCamera*(
    frustumLength, aspectRatio, nearClip, farClip: GLfloat
): RasterizedCamera =
  result = RasterizedCamera(
    kind: Orthographic,
    aspectRatio: aspectRatio,
    frustumLength: frustumLength,
    nearClip: nearClip,
    farClip: farClip,
  )
  result.updateProjectionMat()

proc setOrthographic*(
    c: var RasterizedCamera, frustumLength, aspectRatio, nearClip, farClip: GLfloat
) =
  c.kind = Orthographic
  c.frustumLength = frustumLength
  c.aspectRatio = aspectRatio
  c.nearClip = nearClip
  c.farClip = farClip
  c.updateProjectionMat()

proc getTransformMat*(t: Transform): Mat4f =
  var scaleMat, translateMat, rotateMat = mat4f(1.0)
  # Scaling
  scaleMat[0, 0] = t.scale.x
  scaleMat[1, 1] = t.scale.y
  scaleMat[2, 2] = t.scale.z

  # Rotation in X -> Y -> Z order (pitch -> yaw -> roll)
  let (cx, cy, cz) = (cos(t.rotation.x), cos(t.rotation.y), cos(t.rotation.z))
  let (sx, sy, sz) = (sin(t.rotation.x), sin(t.rotation.y), sin(t.rotation.z))
  rotateMat.row0 = vec4f(cy * cz, -cy * sz, sy, 0.0)
  rotateMat.row1 = vec4f(sx * sy * cz + cx * sz, -sx * sy * sz + cx * cz, -sx * cy, 0.0)
  rotateMat.row2 = vec4f(-cx * sy * cz + sx * sz, cx * sy * sz + sx * cz, cx * cy, 0.0)

  # Translation
  translateMat[3, 0] = t.pos.x
  translateMat[3, 1] = t.pos.y
  translateMat[3, 2] = t.pos.z
  return translateMat * rotateMat * scaleMat

proc getLocalDirections*(c: RasterizedCamera): tuple[forward, right, up: Vec3f] =
  let
    cosPitch = cos(c.pitch)
    sinPitch = sin(c.pitch)
    # Make camera look forward (-Z) when yaw is 0
    cosYaw = cos(c.yaw + PI / 2)
    sinYaw = sin(c.yaw + PI / 2)
    forward = vec3f(cosPitch * -cosYaw, sinPitch, cosPitch * -sinYaw).normalize()
    right = cross(forward, vec3f(0, 1, 0)).normalize()
    up = cross(right, forward)
  return (forward, right, up)

proc getCameraViewMat(c: RasterizedCamera): Mat4f =
  let (forward, _, up) = c.getLocalDirections()
  return lookAt(c.pos, c.pos + forward, up)

proc updateTransform*(c: var RasterizedCamera) =
  if c.rasterizerOn:
    c.viewMat = c.getCameraViewMat()

proc moveLocally*(
    c: var RasterizedCamera, co: FpCameraOptions, moveDirection: Vec3f, dt: float
) =
  let moveBy = moveDirection.normalize() * co.moveSpeed * dt
  let (forward, right, up) = c.getLocalDirections()
  let moveByWorldSpace = moveBy.x * right + moveBy.y * up - moveBy.z * forward
  c.pos += moveByWorldSpace

proc rotate*(c: var RasterizedCamera, co: FpCameraOptions, deltaX, deltaY: float) =
  let deltaYaw = deltaX * co.yawScale * co.sensitivity
  let deltaPitch = deltaY * co.pitchScale * co.sensitivity

  c.yaw += deltaYaw
  c.pitch += deltaPitch

  # Prevent vertical flipping
  c.pitch = c.pitch.clamp(-PI / 2 + PI / 256, PI / 2 - PI / 256)
  # Keep yaw in -180 .. 180 degrees
  if c.yaw > PI:
    c.yaw -= 2 * PI
  if c.yaw < -PI:
    c.yaw += 2 * PI

proc doFirstPersonCameraMovement*(
    c: var RasterizedCamera,
    co: FpCameraOptions,
    moveDirection: Vec3f,
    deltaX, deltaY, dt: float,
) =
  var tChanged = false
  if moveDirection != vec3f(0):
    # Quick and messy fix for weird feeling vertical movement (doesn't use "correct" move speed)
    let moveDirectionPlane = vec3f(moveDirection.x, 0, moveDirection.z)
    if moveDirectionPlane != vec3f(0):
      c.moveLocally(co, moveDirectionPlane, dt)
    c.pos.y += moveDirection.y * co.moveSpeed * dt
    tChanged = true
  if (deltaX, deltaY) != (0.0, 0.0):
    c.rotate(co, deltaX, -deltaY)
    tChanged = true

  if tChanged:
    c.updateTransform()
    (c.forward, c.right, c.up) = c.getLocalDirections()

# ======================================== Models and rasterized scene representation ========================================
# TODO: Proper DAG-based scene graph with model hierarchies
type
  ColoredVertex* = object
    pos*, color*, normal*: Vec3f

  # TODO: Add models with textures
  TexturedVertex* = object
    pos*, normal*: Vec3f
    uv*: Vec2f

  Model*[T] = object
    transform*: Transform
    vertices*: seq[T]
    indices*: seq[GLuint]
      # Indices can be left empty and it means the model has a raw triangle vertex list

  DirectionalLight* = object
    direction*: Vec3f # This should always be normalized
    color*: Vec3f

  Scene*[T] = object
    cam*: RasterizedCamera
    models*: seq[Model[T]]
    dirLight*: DirectionalLight
    ambientLightColor*: Vec3f

makeGlObjects(RaiseError, std140Alignment):
  type PointLight* = object
    position*: Vec3f
    color*: Vec3f
    constTerm*, linearFalloff*, expFalloff*: GLfloat
    padding: uint32
      # Padding to take the size (as std140) up to 48 bytes. For storing inside UBO array.
    # Point lights should have a max range as well (or alternatively a minimum intensity for the light to be considered visible)

proc posColorNorm*(pos, color, normal: Vec3f): ColoredVertex =
  ColoredVertex(pos: pos, color: color, normal: normal)

proc posUvNorm*(pos: Vec3f, uv: Vec2f, normal: Vec3f): TexturedVertex =
  TexturedVertex(pos: pos, uv: uv, normal: normal)

proc initModel*[T](
    vertices: seq[T], indices: seq[GLuint] = @[], transform = Transform()
): Model[T] =
  Model[T](vertices: vertices, indices: indices, transform: transform)

proc initScene*[T](
    cam: RasterizedCamera,
    models: seq[Model[T]] = @[],
    dirLight = DirectionalLight.none,
    ambientLight = Vec3f.none,
): Scene[T] =
  result = Scene[T](cam: cam, models: models)
  if dirLight.isSome:
    result.dirLight = dirLight.get
  if ambientLight.isSome:
    result.ambientLightColor = ambientLight.get
