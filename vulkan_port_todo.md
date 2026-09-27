# Vulkan 1.4 Port Migration TODO

This checklist tracks the implementation of the Vulkan 1.4 compute stream port on branch `vulkan-port`, mapped against the checkpoints defined in `vulkan_port_plan.md` and ongoing implementation reviews.

---

## Checkpoint Progress

### [x] Checkpoint 0: Baseline Capture & Automated Diff Harness
- [x] Capture golden `.ppm` images from OpenGL compute baseline (`BasicLit`, `ShadowedLit`, `Unlit`, `DebugNormals`, `DebugSteps`).
- [x] Create Python parity comparison tool (`tests/diff_images.py`) with MSE/PSNR calculation and delta heatmap generation.
- [x] Verify comparison script against golden references.

### [ ] Checkpoint 1: Co-Design & Finalization of GFX RHI + Slang Integration via 2D Test
- [x] Implement lightweight `GpuStream.nim` RHI (device initialization, stream recording, memory slice allocation with BDA).
- [x] Implement compile-time `SlangIntegration.nim` using `treeform/jsony` to parse reflection JSON and synthesize Nim types.
- [x] Update `Slangc.nim` with `ShaderDataLayout` options (`CLayout`, `Scalar`, etc.) and target-aware profile handling (omit GLSL profiles when compiling for Vulkan SPIR-V).
- [x] Implement 2D animated SDF circle compute shader (`shaders/Test2D.slang`) and host test runner (`tests/test_checkpoint1.nim`).
- [x] Support headless screenshot readback and automated window presentation.
- [ ] Address remaining phase 1 architectural items (generalizing dispatch and robust surface resize handling).

### [ ] Checkpoint 2: Full SDF Slang Shader BDA Migration & Reflection Test
- [ ] Refactor `shaders/SdfRenderer.slang` to use 64-bit BDA pointers in push constants (`SdfPushParams`).
- [ ] Replace structured buffer indexing with direct pointer dereferencing in Slang.
- [ ] Invoke `importSlangShader` on the full SDF shader and verify type generation for `SceneUniforms`, `DebugSettings`, `Material`, `SdfInstruction`, `PointLight`, and `SdfPushParams`.
- [ ] Verify SPIR-V compilation with `VK_EXT_shader_object` compatibility.

### [ ] Checkpoint 3: SdfRenderer CPU-Side Port & Visual Parity Verification
- [ ] Replace OpenGL allocations with `GpuSlice[T]` in `SdfRenderer.nim`.
- [ ] Wire camera uniforms, dynamic objects, and CSG instruction buffer into mapped VRAM.
- [ ] Record dispatches and present passes on `GpuStream`.
- [ ] Run automated visual diff (`tests/diff_images.py`) against all 5 golden images (target: MSE < 0.5).

### [ ] Checkpoint 4: End-to-End Automated Testing (Input & Resizing) & Merging
- [ ] Automated input tests (camera movement, mode switching hotkeys).
- [ ] Window resizing validation under Wayland / X11 (swapchain recreation).
- [ ] Remove legacy OpenGL files (`src/GlUtils.nim`, `src/glad/`).
- [ ] Update Nimble configuration and merge `vulkan-port` branch back to `dev`.

---

## Implementation Review & Issues Log

The following issues were identified during architectural and system reviews:

### 🔴 Critical Issues
- [x] **Color Channel Inversion Hazard with `vkCmdCopyImage2`**:
  - *Identified*: `GpuTarget.storageImage` was fixed to `VK_FORMAT_R8G8B8A8_UNORM`. When swapchains negotiated `VK_FORMAT_B8G8R8A8_UNORM`, raw block copying swapped red and blue channels.
  - *Fix Applied*: Storage image format now matches `swapchain.format` directly, and readback PPM logic swizzles BGRA to RGB when needed.
- [x] **Unconditional `{.packed.}` in Slang Macro**:
  - *Identified*: Naked `{.packed.}` without matching layout rules caused potential padding misalignments between Slang std430 vectors and Nim objects.
  - *Fix Applied*: Shaders are compiled via `Slangc.nim` using `-fvk-use-c-layout` (matching standard C struct ABI). Slang integration macro generates standard Nim objects matching the C struct ABI without manual padding or `{.packed.}`.
- [x] **Semaphore Wait Stage in `present`**:
  - *Identified*: `imageAvailableSem` was waited on at `COMPUTE_SHADER_BIT`, causing compute dispatches to stall unnecessarily on swapchain image acquisition.
  - *Fix Applied*: Upgraded submission to `vkQueueSubmit2` and set semaphore wait stage strictly to `VK_PIPELINE_STAGE_2_TRANSFER_BIT`.

### 🟠 High Priority / Ergonomics
- [ ] **`dispatch` Hardcoded to `GpuTarget`**:
  - *Issue*: `stream.dispatch` currently requires passing `target: GpuTarget` and automatically binds descriptor binding 0 to `target.storageView`. Checkpoint 2 and multi-pass compute pipelines require buffer-to-buffer dispatches or multiple textures.
  - *Action*: Decouple `stream.dispatch` into a general form (`stream.dispatch(shader, push, wgX, wgY, wgZ)`) with explicit descriptor binding helpers or binding abstractions.
- [ ] **Surface Leak & Missing Resize Support**:
  - *Issue*: `vulkanCreateSurface` handle was discarded in a local variable instead of being saved in `GpuTarget`. Window resizing currently causes `beginFrame` to spin without swapchain recreation.
  - *Status*: Surface handle is now retained in `GpuTarget`, but swapchain recreation logic (`target.resize(w, h)`) is pending implementation.
- [x] **Hardcoded `"main"` in `loadComputeShader`**:
  - *Identified*: The `entryName` argument in `loadComputeShader` was ignored and `"main"` was hardcoded in `VkShaderCreateInfoEXT`.
  - *Fix Applied*: `entryName.cstring` is passed to `pName` in `VkShaderCreateInfoEXT`.
