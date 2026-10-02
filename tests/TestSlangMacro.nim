import SlangIntegration

const shaderData = compileSlangShader("shaders/Test2D.slang")
generateNimObjects(parseShaderReflection(shaderData), ["TestParams", "PushConstants"])

var p: TestParams
p.colorA = [1.0f32, 0.0f32, 0.0f32, 1.0f32]
p.colorB = [0.0f32, 1.0f32, 0.0f32, 1.0f32]
p.center = [0.0f32, 0.0f32]
p.radius = 0.5f32
p.time = 1.0f32
p.aspectRatio = 1.777f32

var push: PushConstants
push.params = 12345678'u64

echo "TestParams size: ", sizeof(TestParams)
echo "PushConstants size: ", sizeof(PushConstants)
echo "Workgroup size: ", (shaderData.workgroupX, shaderData.workgroupY, shaderData.workgroupZ)
echo "Shader binary path: ", shaderData.spvPath
