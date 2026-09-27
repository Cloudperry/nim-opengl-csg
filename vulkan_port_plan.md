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

---

## 5. Future Work

1. **Slang / Nim Struct Layout Verification**:
   - Add compile-time layout verification in the Slang Integration macro: validate `offsetOf(NimType, field) == slangField.binding.offset` and `sizeof(NimType) == slangStruct.sizes[0].value`.
   - Provide detailed compile-time diagnostic error messages if any compiler ABI difference or struct packing discrepancy is detected between the host C ABI and SPIR-V scalar layout.
2. **Zero-Copy Swapchain Storage Image**:
   - Investigate direct rendering to swapchains created with `VK_IMAGE_USAGE_STORAGE_BIT` where supported by the presentation engine, completely eliminating the copy/present pass.
3. **Decoupled Multi-Pass Compute Dispatches**:
   - Generalize `stream.dispatch` to support arbitrary buffer-to-buffer and multi-texture compute passes (e.g. bounding hierarchy acceleration, ray marching, and post-processing).
