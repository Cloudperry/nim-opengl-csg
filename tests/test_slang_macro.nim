import SlangIntegration

importSlangShader("shaders/Test2D.slang", ["TestParams", "PushConstants"])

var p: TestParams
p.colorA = [1.0f32, 0.0f32, 0.0f32, 1.0f32]
p.colorB = [0.0f32, 1.0f32, 0.0f32, 1.0f32]
p.center = [0.0f32, 0.0f32]
p.radius = 0.5f32
p.time = 1.0f32
p.aspectRatio = 1.777f32

var push: PushConstants
push.params = 12345678'u64

let meta = getShaderMeta_Test2D()
let binPath = getShaderBinaryPath_Test2D()
echo "TestParams size: ", sizeof(TestParams)
echo "PushConstants size: ", sizeof(PushConstants)
echo "Workgroup size: ", meta
echo "Shader binary path: ", binPath
