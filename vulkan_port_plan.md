# Concrete Implementation & Porting Plan: Vulkan 1.4 Compute Stream RHI

> **Git Branch Policy:** All Vulkan migration work is developed and tested on the dedicated branch: `vulkan-port`.

---

## 1. Executive Summary & Design Overview

This plan defines an end-to-end strategy for transitioning the CSG/SDF sphere tracing renderer from OpenGL 4.6 to Vulkan 1.4. The architecture is built around a dedicated **Compute Stream & Direct Memory** abstraction paired with an **outside-in, bottom-up migration** strategy, modern Vulkan 1.4 core features, automated Slang reflection codegen, and Python-driven visual parity testing.

### Key Architectural Decisions
1. **Compute-Only Stream Paradigm (`GpuStream`)**:
   - The GPU is treated as a parallel compute coprocessor. Commands (barriers, shader dispatches, memory copies) are recorded onto a lightweight stream.
   - No rasterization baggage: zero vertex arrays, zero blend states, zero depth-stencil buffers, and zero legacy render passes.
2. **Buffer Device Address (BDA) via Push Constants**:
   - Replaces OpenGL SSBO and UBO bindings with native 64-bit GPU virtual addresses (`uint64`).
   - Pointers are passed directly into the compute shader via Vulkan Push Constants. The shader dereferences them using native Slang pointer syntax (`SceneUniforms* u = (SceneUniforms*)push.sceneAddr;`).
3. **Push Descriptors for the Output Target**:
   - The single compute output texture (`RWTexture2D<float4>`) is bound using Vulkan 1.4 core Push Descriptors (`vkCmdPushDescriptorSet`).
   - Completely eliminates `VkDescriptorPool`, `VkDescriptorSet`, and descriptor set allocation overhead.
4. **Presentation via `vkCmdCopyImage2`**:
   - Compute outputs to an offscreen storage image matching the swapchain format.
   - Presentation uses `vkCmdCopyImage2` (Vulkan 1.3/1.4 core) for direct, zero-filtering VRAM-to-VRAM copy to the swapchain image.
   - *Future Optimization Note:* When drivers and platforms support `VK_IMAGE_USAGE_STORAGE_BIT` on swapchain images, the compute shader can write directly to the swapchain backbuffer, eliminating the copy step entirely.
5. **Slang Reflection & Nim Codegen (`treeform/jsony`)**:
   - A dedicated Slang integration API compiles Slang to SPIR-V, generates JSON reflection, and synthesizes matching Nim object types.
   - Extracts workgroup dimensions (`[8, 8, 1]`), push constant layout, and resource bindings automatically.
6. **File Organization Principle**:
   - **Prefer fewer files.** Keep cohesive functionality together in compact, self-contained modules rather than creating an explosion of micro-files. File boundaries will be refined organically during implementation.

---

## 2. Context for an OpenGL Programmer

For developers familiar with modern OpenGL (4.3–4.6 compute), the following table maps familiar OpenGL concepts directly to this modern Vulkan 1.4 compute architecture:

| OpenGL Concept | Modern Vulkan 1.4 Equivalent in this RHI | Why it's Better |
| :--- | :--- | :--- |
| **SSBO** (`glBindBufferBase(GL_SHADER_STORAGE_BUFFER, b, id)`) | **Buffer Device Address (BDA)**: 64-bit pointer (`uint64`) | Zero binding slots or descriptor sets. Shader uses standard C pointers (`T* ptr = (T*)push.addr;`). |
| **Uniform Buffers** (`glBindBufferBase(GL_UNIFORM_BUFFER, ...)`) | Same as above: BDA pointer in Push Constants | Eliminates `std140` padding gymnastics; same pointer semantics for all data. |
| **`glUniform*`** | **Push Constants** (`vkCmdPushConstants`) | Latency-free, CPU-to-command-buffer inline data (128+ bytes guaranteed). |
| **`glBindImageTexture(...)`** | **Push Descriptors** (`vkCmdPushDescriptorSet`) | No descriptor pool allocation; image view bound directly into command stream. |
| **`glDispatchCompute(gx, gy, gz)`** | `vkCmdDispatch(cmd, gx, gy, gz)` | Identical workgroup dispatch model. |
| **`glMemoryBarrier(GL_FRAMEBUFFER_BARRIER_BIT)`** | `vkCmdPipelineBarrier2` (`VK_KHR_synchronization2`) | Explicit 64-bit pipeline stage and access masks; no GPU driver guesswork. |
| **`glBlitFramebuffer(...)`** | `vkCmdCopyImage2` | Fast, direct hardware copy engine from storage image to swapchain backbuffer. |
| **`glfwSwapBuffers` / `SDL_GL_SwapWindow`** | `vkQueuePresentKHR` | Explicit presentation engine with semaphore synchronization. |

---

## 3. Core API Specifications (Draft Baselines)

> **Design Fluidity Note:** The types and signatures below represent the baseline design target. The exact type definitions and API surface will be refined and finalized during Checkpoint 1. The Slang integration API and the GFX stream abstraction should inform each other—if adjusting the abstraction makes the Slang integration cleaner, or if a simpler implementation is discovered while writing real code, the designs should evolve accordingly.

### 3.1 GFX API Abstraction ("Compute Stream & Direct Memory")

The core GFX abstraction is minimal, standalone, and decoupled from SDF-specific logic:

```nim
type
  GpuDevice* = ref object
    instance*: VkInstance
    physicalDevice*: VkPhysicalDevice
    device*: VkDevice
    queue*: VkQueue
    queueFamilyIndex*: uint32
    cmdPool*: VkCommandPool
    computeLayout*: VkPipelineLayout
    descriptorLayout*: VkDescriptorSetLayout

  GpuSlice*[T] = object
    ## Typed GPU memory slice with persistent host mapping and 64-bit device address.
    buffer*: VkBuffer
    memory*: VkDeviceMemory
    deviceAddress*: uint64             ## 64-bit BDA pointer passed to shaders
    hostPtr*: ptr UncheckedArray[T]    ## Direct mapped memory pointer for zero-copy CPU writes
    len*: int

  GpuTarget* = ref object
    ## Offscreen storage image + swapchain backbuffer linkage.
    storageImage*: VkImage
    storageView*: VkImageView
    width*, height*: int32
    format*: VkFormat
    swapchain*: VkSwapchainKHR
    swapchainImages*: seq[VkImage]
    currentSwapImageIndex*: uint32

  ComputeShader* = ref object
    device*: GpuDevice
    handle*: VkShaderEXT               ## Shader Object (VK_EXT_shader_object)

  GpuStream* = ref object
    ## Lightweight queue command stream.
    device*: GpuDevice
    cmdBuffer*: VkCommandBuffer
    inFlightFence*: VkFence
    imageAvailableSem*: VkSemaphore
    renderFinishedSem*: VkSemaphore
```

#### Core GFX API Surface:
```nim
# Device Lifecycle
proc initGpuDevice*(win: Window): GpuDevice
proc destroy*(device: var GpuDevice)

# Type-Safe Memory Allocation & Writing Helpers
proc allocSlice*[T](device: GpuDevice, count: int): GpuSlice[T]
proc dealloc*[T](slice: var GpuSlice[T])
template `[]`*[T](slice: GpuSlice[T], index: int): lent T = slice.hostPtr[index]
template `[]=`*[T](slice: var GpuSlice[T], index: int, val: T) = slice.hostPtr[index] = val
proc writeSlice*[T](slice: var GpuSlice[T], data: openArray[T], dstOffset = 0)

# Target & Swapchain
proc createTarget*(device: GpuDevice, win: Window, width, height: int32): GpuTarget
proc resize*(target: var GpuTarget, width, height: int32)
proc destroy*(target: var GpuTarget)

# Shader Objects
proc loadComputeShader*(device: GpuDevice, spvCode: string): ComputeShader
proc destroy*(shader: var ComputeShader)

# Stream Execution
proc initGpuStream*(device: GpuDevice): GpuStream
proc beginFrame*(stream: GpuStream, target: GpuTarget): bool
proc dispatch*[PushT: object](
  stream: GpuStream,
  shader: ComputeShader,
  target: GpuTarget,
  pushConstants: PushT,
  workgroupsX, workgroupsY, workgroupsZ: uint32
)
proc present*(stream: GpuStream, target: GpuTarget)
  ## 1. PipelineBarrier2: Storage -> TRANSFER_SRC, Swapchain -> TRANSFER_DST
  ## 2. vkCmdCopyImage2: Exact 1:1 VRAM copy from storage image to swapchain
  ## 3. PipelineBarrier2: Swapchain -> PRESENT_SRC
  ## 4. vkQueueSubmit + vkQueuePresentKHR
```

---

### 3.2 Dedicated Slang Integration API

Rather than tightly coupling shader compilation into the GFX device, the **Slang Integration API** acts as a metadata and codegen provider that feeds cleanly into the GFX abstraction:

#### Design Approach
1. **Compilation & Reflection Pipeline**:
   - Slang compiles `.slang` to SPIR-V and outputs a JSON reflection file (`-target spirv -dump-reflection -reflection-output <file>.json`).
   - JSON parsing is performed using **`treeform/jsony`**.
2. **Nim Object Generation from Reflection**:
   - The user declares a shader and the list of struct types to import:
     ```nim
     importSlangShader("shaders/SdfRenderer.slang",
       types = ["SceneUniforms", "DebugSettings", "Material", "SdfInstruction", "PointLight", "SdfPushParams"]
     )
     ```
   - The API inspects the Slang reflection JSON at compile time.
   - For every declared type, it emits matching Nim types with standard C-struct layout, guaranteeing identical memory alignment without manual offset coding.
   - For BDA pointers in Slang (`T*`), the API generates `uint64` fields in the Nim push constant struct.
3. **Dispatch Information & Ergonomics**:
   - The integration provides typed metadata (e.g. workgroup dimensions `[8, 8, 1]`, push constant byte size, and binding indices).
   - Can either layer on top of the GFX wrapper or provide data structures directly to the stream dispatch calls—whichever proves most ergonomic when writing the test program.

---

## 4. Concrete Phased Porting Plan & Checkpoints

```
[Branch: vulkan-port]
        |
[Checkpoint 0: Baseline Capture & Automated Diff Harness]
        |
[Checkpoint 1: Co-Design & Finalization of GFX RHI + Slang Integration via 2D Test]
        |
[Checkpoint 2: Full SDF Slang Shader BDA Migration & Reflection Test]
        |
[Checkpoint 3: SdfRenderer CPU-Side Port & Visual Parity Verification]
        |
[Checkpoint 4: End-to-End Automated Testing (Input & Resizing) & Merging]
```

---

### Checkpoint 0: Baseline Capture & Automated Diff Harness
- **Goal:** Establish reference images from the current OpenGL compute renderer across all shading modes.
- **Actions:**
  1. Capture 5 golden `.ppm` images using the existing CLI parameters (`--camLock*`, `--lockTime=1.5`, `--screenshotPath`):
     - `ref_basic.ppm` (`BasicLitScene`)
     - `ref_shadows.ppm` (`ShadowedLitScene`)
     - `ref_unlit.ppm` (`UnlitScene`)
     - `ref_normals.ppm` (`DebugNormals`)
     - `ref_steps.ppm` (`DebugStepCounts`)
  2. Create a Python-based visual parity comparison script (`tests/diff_images.py`) using **Pillow / NumPy**:
     - Computes Mean Squared Error (MSE), Peak Signal-to-Noise Ratio (PSNR), and maximum per-channel delta.
     - Saves an exaggerated color difference heatmap image (`diff_heatmap.png`) if delta exceeds threshold.
- **Verification Criteria:**
  - Running `python3 tests/diff_images.py tests/golden/ref_basic.ppm tests/golden/ref_basic.ppm` outputs `MSE: 0.0, PASS`.

---

### Checkpoint 1: Co-Design & Finalization of GFX RHI + Slang Integration via 2D Test
- **Goal:** Simultaneously build, test, and co-design the minimal GFX stream abstraction and the Slang integration API by implementing a simplified 2D compute rendering test.
- **Co-Design & Fluidity Principle:**
  - The GFX API abstraction design and the Slang integration API design are **not set in stone** beforehand. They must be finalized iteratively while writing the actual implementation and test program.
  - If the implementing agent finds cleaner, simpler, or more natural ways of expressing concepts in code, the designs can and should change.
  - The Slang integration and GFX abstraction must work seamlessly together: adjustments to one API to improve the ergonomics of the other are encouraged.
- **Actions:**
  1. Build the Slang reflection parser and codegen mechanism using `treeform/jsony`.
  2. Create a test 2D shader (`shaders/Test2D.slang`):
     - Takes a `TestParams` struct (aspect ratio, time, circle radius, color) via BDA pointer in push constants.
     - Evaluates a 2D signed distance field (SDF) of a circle (`length(uv) - radius`) with smooth antialiased edge rendering, and writes to `RWTexture2D<float4>`.
     - Draws a 2D SDF circle that smoothly shifts color palette over time.
  3. Use the new Slang integration API to import the shader and generate Nim-side objects for the declared structs from reflection JSON.
  4. Build the GFX stream abstraction (device, stream, memory slices, target, shader object, `vkCmdCopyImage2` presentation).
  5. In a test program:
     - Verify that the generated Nim objects match what was expected from the test shader.
     - Allocate a `GpuSlice[TestParams]` with type-safe helpers and populate it in host memory (updating time/colors per frame).
     - Dispatch compute on `GpuStream` and present via `vkCmdCopyImage2`.
     - Support both SDL3 window display and headless screenshot output.
- **Verification Criteria:**
  - Automated test executes cleanly without Vulkan validation errors.
  - Generated Nim-side objects match the declared Slang structs.
  - Real, simplified 2D rendering produces the expected visual output (smooth 2D SDF circle with animated color shifts) in both windowed and headless modes.

---

### Checkpoint 2: Full SDF Slang Shader BDA Migration & Reflection Test
- **Goal:** Modernize the full 3D CSG/SDF compute shader to use BDA pointers and push constants, verified by the Slang Integration API.
- **Actions:**
  1. Refactor `shaders/SdfRenderer.slang` (or create `shaders/SdfRendererVk.slang`):
     - Replace OpenGL descriptor bindings with 64-bit BDA pointers in push constants:
       ```slang
       struct SdfPushParams {
           SceneUniforms*   scene;
           DebugSettings*   debugOpt;
           SdfProgramData*  progData;
           SdfInstruction*  prog;
           PointLight*      pointLights;
           uint32_t*        progArgs;
           uint32_t         lightCount;
           uint32_t         instructionCount;
       };
       [[vk::push_constant]] SdfPushParams push;
       [[vk::image_format("rgba8")]] [[vk::binding(0, 0)]] RWTexture2D<float4> outImage;
       ```
     - Replace structured buffer accesses with direct pointer indexing.
  2. Invoke the Slang Integration API on the updated shader:
     - Test that the JSON-generated Nim objects for `SceneUniforms`, `DebugSettings`, `SdfProgramData`, `SdfInstruction`, `PointLight`, and `SdfPushParams` match expectations.
     - Test that workgroup size, push constant size, and image binding information are retrieved successfully.
- **Verification Criteria:**
  - Standalone reflection test passes: generated Nim types compile and assert compatibility with Slang reflection data.
  - SPIR-V compiles cleanly with `VK_EXT_shader_object` compatibility.

---

### Checkpoint 3: SdfRenderer CPU-Side Port & Visual Parity Verification
- **Goal:** Port the CPU-side renderer logic from OpenGL to Vulkan, wire up the scene builder, and verify pixel parity against the OpenGL baseline.
- **CPU-Side Porting Outline:**
  1. **Replace OpenGL Allocations with `GpuSlice[T]`**:
     - `sceneUniforms: GpuSlice[SceneUniforms]` (1 element)
     - `debugSettings: GpuSlice[DebugSettings]` (1 element)
     - `materials: GpuSlice[Material]` (256 elements)
     - `instructions: GpuSlice[SdfInstruction]` (dynamic slice)
     - `args: GpuSlice[uint32]` (dynamic slice)
     - `pointLights: GpuSlice[PointLight]` (dynamic slice)
  2. **Scene & Camera Synchronization**:
     - Update camera matrices and uniforms directly into `sceneUniforms[0]`.
     - In `dynamicObjectsScene()`, update the moving cutter and sphere directly in mapped `args` memory.
     - Upload CSG instruction buffer via `writeSlice()`.
  3. **Stream Recording & Copy Presentation**:
     - Record `stream.dispatch(...)` with BDA pointers.
     - Record `stream.present(...)` with `vkCmdCopyImage2`.
  4. **Headless Readback**:
     - Support `--screenshotPath` by copying the offscreen storage image to a host-visible buffer via `vkCmdCopyImageToBuffer` and saving a `.ppm`.
  5. **Visual Parity Test**:
     - Use Python (`tests/diff_images.py`) for automated visual parity testing of the renderer against all 5 golden images from Checkpoint 0.
- **Verification Criteria:**
  - Python visual diff achieves **MSE < 0.5** across all 5 render modes against the OpenGL baseline.
  - Zero Vulkan validation layer warnings or errors.

---

### Checkpoint 4: End-to-End Automated Testing (Input & Resizing) & Merging
- **Goal:** Verify full application functionality under SDL3 and prepare for merging into `dev`.
- **Actions:**
  1. **Automated Input & Interactive Testing**:
     - Simulate keyboard events (WASD camera movement, ESC to quit).
     - Simulate mode toggle hotkeys (F1: BasicLit, F2: ShadowedLit, F3: Unlit, F5: Normals, F6: Steps) and verify mode changes via screenshots.
     - Only one or two tests per feature are needed.
  2. **Window Resizing Validation**:
     - Test window resize events (e.g. 1280x720 -> 1600x900 -> 1280x720) on Plasma Wayland / X11.
     - Verify swapchain recreation and offscreen target resizing without flickering or distortion.
  3. **Clean Up & Documentation**:
     - Remove obsolete OpenGL files (`src/GlUtils.nim`, `src/glad/`).
     - Update `CsgRenderer.nimble` dependencies and bin definitions.
     - Merge `vulkan-port` branch back into `dev`.
- **Verification Criteria:**
  - All automated input and resize tests pass.
  - Interactive test runs smoothly at full display refresh rate with clean exit.
