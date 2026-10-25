// Xenia source excerpt. Copyright 2022 Ben Vanik.
// BSD-3-Clause; see LICENSE.
  const Shader::ConstantRegisterMap& constant_map_vertex =
      vertex_shader->constant_register_map();
  // Pixel shaders may also issue vfetch (for example, Rise's morph passes).
  // Their buffers must be resident and current before any stage reads them.
  const Shader::ConstantRegisterMap* constant_map_pixel =
      pixel_shader ? &pixel_shader->constant_register_map() : nullptr;
  {
    uint32_t vfetch_addresses[96];
    uint32_t vfetch_sizes[96];
    uint32_t vfetch_current_queued = 0;
    for (uint32_t i = 0;
         i < xe::countof(constant_map_vertex.vertex_fetch_bitmap); ++i) {
      uint32_t vfetch_bits_remaining =
          constant_map_vertex.vertex_fetch_bitmap[i];
      if (constant_map_pixel) {
        vfetch_bits_remaining |= constant_map_pixel->vertex_fetch_bitmap[i];
      }
      uint32_t j;
      while (xe::bit_scan_forward(vfetch_bits_remaining, &j)) {
        vfetch_bits_remaining = xe::clear_lowest_bit(vfetch_bits_remaining);
        uint32_t vfetch_index = i * 32 + j;
        xenos::xe_gpu_vertex_fetch_t vfetch_constant =
            regs.GetVertexFetch(vfetch_index);
        switch (vfetch_constant.type) {
          case xenos::FetchConstantType::kVertex:
            break;
          case xenos::FetchConstantType::kInvalidVertex:
            if (cvars::gpu_allow_invalid_fetch_constants) {
              break;
            }
            XELOGW(
                "Vertex fetch constant {} ({:08X} {:08X}) has \"invalid\" "
                "type! "
                "This is incorrect behavior, but you can try bypassing this by "
                "launching Xenia with "
                "--gpu_allow_invalid_fetch_constants=true.",
                vfetch_index, vfetch_constant.dword_0, vfetch_constant.dword_1);
            return false;
          default:
            XELOGW(
                "Vertex fetch constant {} ({:08X} {:08X}) is completely "
                "invalid!",
                vfetch_index, vfetch_constant.dword_0, vfetch_constant.dword_1);
            return false;
        }
        // Mask to physical like the shader - the guest may use a mirror window.
        vfetch_addresses[vfetch_current_queued] =
            xenos::CpuToGpu(vfetch_constant.address << 2) >> 2;
        vfetch_sizes[vfetch_current_queued++] = vfetch_constant.size;
      }
    }

    if (vfetch_current_queued) {
      // so far, i have never seen vfetch_current_queued > 4. 1 is most common,
      // 2 happens occasionally. did not test many games though pre-acquire the
      // critical region so we're not repeatedly re-acquiring it in requestrange
      auto shared_memory_request_range_hoisted =
          global_critical_region::Acquire();

      for (uint32_t i = 0; i < vfetch_current_queued; ++i) {
        if (!shared_memory_->RequestRange(vfetch_addresses[i] << 2,
                                          vfetch_sizes[i] << 2)) {
          XELOGE(
              "Failed to request vertex buffer at 0x{:08X} (size {}) in the "
              "shared memory",
              vfetch_addresses[i] << 2, vfetch_sizes[i] << 2);
          return false;
        }
      }
    }
  }
