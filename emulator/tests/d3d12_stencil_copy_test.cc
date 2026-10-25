// Windows-only real-device check for single-sample stencil plane copies.
// Verifies partial rectangle contents, unchanged outside bytes and depth.
// Link with d3d12, dxgi and dxguid; no graphics tools installation is required.
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <vector>
#include <windows.h>
#include <wrl/client.h>
using Microsoft::WRL::ComPtr;
static void check(HRESULT hr, const char *what) {
  if (FAILED(hr)) {
    std::printf("FAIL %s: %08lX\n", what, (unsigned long)hr);
    throw 1;
  }
}
static D3D12_RESOURCE_BARRIER
barrier(ID3D12Resource *r, D3D12_RESOURCE_STATES a, D3D12_RESOURCE_STATES b) {
  D3D12_RESOURCE_BARRIER x = {};
  x.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
  x.Transition.pResource = r;
  x.Transition.StateBefore = a;
  x.Transition.StateAfter = b;
  x.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
  return x;
}
static ComPtr<ID3D12Resource> buffer(ID3D12Device *d, UINT64 size,
                                     D3D12_HEAP_TYPE heap,
                                     D3D12_RESOURCE_STATES state) {
  D3D12_HEAP_PROPERTIES h = {};
  h.Type = heap;
  D3D12_RESOURCE_DESC r = {};
  r.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
  r.Width = size;
  r.Height = 1;
  r.DepthOrArraySize = 1;
  r.MipLevels = 1;
  r.SampleDesc.Count = 1;
  r.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
  ComPtr<ID3D12Resource> out;
  check(d->CreateCommittedResource(&h, D3D12_HEAP_FLAG_NONE, &r, state, nullptr,
                                   IID_PPV_ARGS(&out)),
        "buffer");
  return out;
}
static D3D12_TEXTURE_COPY_LOCATION plane(ID3D12Resource *r, UINT n) {
  D3D12_TEXTURE_COPY_LOCATION x = {};
  x.pResource = r;
  x.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
  x.SubresourceIndex = n;
  return x;
}
static D3D12_TEXTURE_COPY_LOCATION
placed(ID3D12Resource *r, D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp) {
  D3D12_TEXTURE_COPY_LOCATION x = {};
  x.pResource = r;
  x.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
  x.PlacedFootprint = fp;
  return x;
}
int main() {
  try {
    ComPtr<ID3D12Debug> debug;
    bool validated = SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)));
    if (validated)
      debug->EnableDebugLayer();
    std::printf("DebugLayer=%d\n", validated);
    ComPtr<IDXGIFactory4> factory;
    check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)), "factory");
    ComPtr<IDXGIAdapter1> adapter;
    check(factory->EnumAdapters1(0, &adapter), "adapter");
    DXGI_ADAPTER_DESC1 ad = {};
    adapter->GetDesc1(&ad);
    std::printf("Adapter=%ls\n", ad.Description);
    ComPtr<ID3D12Device> device;
    check(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0,
                            IID_PPV_ARGS(&device)),
          "device");
    ComPtr<ID3D12CommandQueue> queue;
    D3D12_COMMAND_QUEUE_DESC q = {};
    check(device->CreateCommandQueue(&q, IID_PPV_ARGS(&queue)), "queue");
    ComPtr<ID3D12CommandAllocator> alloc;
    check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,
                                         IID_PPV_ARGS(&alloc)),
          "allocator");
    ComPtr<ID3D12GraphicsCommandList> list;
    check(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT,
                                    alloc.Get(), nullptr, IID_PPV_ARGS(&list)),
          "list");
    for (DXGI_FORMAT fmt :
         {DXGI_FORMAT_R32G8X24_TYPELESS, DXGI_FORMAT_R24G8_TYPELESS}) {
      D3D12_RESOURCE_DESC td = {};
      td.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
      td.Width = 63;
      td.Height = 37;
      td.DepthOrArraySize = 1;
      td.MipLevels = 1;
      td.Format = fmt;
      td.SampleDesc.Count = 1;
      td.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
      td.Flags = D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL;
      D3D12_HEAP_PROPERTIES heap = {};
      heap.Type = D3D12_HEAP_TYPE_DEFAULT;
      ComPtr<ID3D12Resource> depth;
      check(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &td,
                                            D3D12_RESOURCE_STATE_COPY_DEST,
                                            nullptr, IID_PPV_ARGS(&depth)),
            "depth texture");
      D3D12_PLACED_SUBRESOURCE_FOOTPRINT fps[2] = {};
      UINT rows[2] = {};
      UINT64 sizes[2] = {}, total = 0;
      device->GetCopyableFootprints(&td, 0, 2, 0, fps, rows, sizes, &total);
      std::printf(
          "DepthFormat=%u Plane1Format=%u RowPitch=%u RowBytes=%llu Rows=%u\n",
          fmt, fps[1].Footprint.Format, fps[1].Footprint.RowPitch,
          (unsigned long long)sizes[1], rows[1]);
      if (sizes[1] != 63 ||
          fps[1].Footprint.Format != DXGI_FORMAT_R8_TYPELESS) {
        std::puts("FAIL unsupported stencil footprint");
        return 2;
      }
      auto upload = buffer(device.Get(), total, D3D12_HEAP_TYPE_UPLOAD,
                           D3D12_RESOURCE_STATE_GENERIC_READ);
      auto readback = buffer(device.Get(), total, D3D12_HEAP_TYPE_READBACK,
                             D3D12_RESOURCE_STATE_COPY_DEST);
      void *mapped = nullptr;
      check(upload->Map(0, nullptr, &mapped), "upload map");
      std::memset(mapped, 0, total);
      for (UINT y = 0; y < 37; y++)
        for (UINT x = 0; x < 63; x++) {
          std::uint32_t z =
              fmt == DXGI_FORMAT_R32G8X24_TYPELESS ? 0x3f000000 : 0x00800000;
          std::memcpy((char *)mapped + fps[0].Offset +
                          y * fps[0].Footprint.RowPitch + x * 4,
                      &z, 4);
          *((std::uint8_t *)mapped + fps[1].Offset +
            y * fps[1].Footprint.RowPitch + x) = 0x5a;
        }
      upload->Unmap(0, nullptr);
      auto dp = plane(depth.Get(), 0), up = placed(upload.Get(), fps[0]);
      list->CopyTextureRegion(&dp, 0, 0, 0, &up, nullptr);
      dp = plane(depth.Get(), 1);
      up = placed(upload.Get(), fps[1]);
      list->CopyTextureRegion(&dp, 0, 0, 0, &up, nullptr);
      D3D12_RESOURCE_DESC rd = td;
      rd.Format = DXGI_FORMAT_R8_UINT;
      rd.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
      ComPtr<ID3D12Resource> scratch;
      check(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &rd,
                                            D3D12_RESOURCE_STATE_COPY_DEST,
                                            nullptr, IID_PPV_ARGS(&scratch)),
            "R8 texture");
      auto b = barrier(depth.Get(), D3D12_RESOURCE_STATE_COPY_DEST,
                       D3D12_RESOURCE_STATE_COPY_SOURCE);
      list->ResourceBarrier(1, &b);
      auto sp = plane(scratch.Get(), 0);
      list->CopyTextureRegion(&sp, 0, 0, 0, &dp, nullptr);
      // Read original stencil through the R8 texture, then replace R8 with a
      // pattern and copy it directly back into depth's stencil plane.
      b = barrier(scratch.Get(), D3D12_RESOURCE_STATE_COPY_DEST,
                  D3D12_RESOURCE_STATE_COPY_SOURCE);
      list->ResourceBarrier(1, &b);
      auto rp = placed(readback.Get(), fps[1]);
      list->CopyTextureRegion(&rp, 0, 0, 0, &sp, nullptr);
      check(list->Close(), "close");
      ID3D12CommandList *lists[] = {list.Get()};
      queue->ExecuteCommandLists(1, lists);
      ComPtr<ID3D12Fence> fence;
      check(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)),
            "fence");
      HANDLE event = CreateEvent(nullptr, FALSE, FALSE, nullptr);
      check(queue->Signal(fence.Get(), 1), "signal");
      check(fence->SetEventOnCompletion(1, event), "event");
      if (WaitForSingleObject(event, 10000) != WAIT_OBJECT_0) {
        std::puts("FAIL GPU timeout");
        return 3;
      }
      check(readback->Map(0, nullptr, &mapped), "readback");
      for (UINT y = 0; y < 37; y++)
        for (UINT x = 0; x < 63; x++)
          if (*((std::uint8_t *)mapped + fps[1].Offset +
                y * fps[1].Footprint.RowPitch + x) != 0x5a) {
            std::puts("FAIL stencil to R8");
            return 4;
          }
      readback->Unmap(0, nullptr);
      check(alloc->Reset(), "reset alloc");
      check(list->Reset(alloc.Get(), nullptr), "reset list");
      check(upload->Map(0, nullptr, &mapped), "upload2");
      for (UINT y = 0; y < 37; y++)
        for (UINT x = 0; x < 63; x++)
          *((std::uint8_t *)mapped + fps[1].Offset +
            y * fps[1].Footprint.RowPitch + x) = std::uint8_t(x * 3 + y * 7);
      upload->Unmap(0, nullptr);
      b = barrier(scratch.Get(), D3D12_RESOURCE_STATE_COPY_SOURCE,
                  D3D12_RESOURCE_STATE_COPY_DEST);
      list->ResourceBarrier(1, &b);
      list->CopyTextureRegion(&sp, 0, 0, 0, &up, nullptr);
      b = barrier(scratch.Get(), D3D12_RESOURCE_STATE_COPY_DEST,
                  D3D12_RESOURCE_STATE_COPY_SOURCE);
      list->ResourceBarrier(1, &b);
      b = barrier(depth.Get(), D3D12_RESOURCE_STATE_COPY_SOURCE,
                  D3D12_RESOURCE_STATE_COPY_DEST);
      list->ResourceBarrier(1, &b);
      D3D12_BOX region = {11, 7, 0, 39, 23, 1};
      list->CopyTextureRegion(&dp, 11, 7, 0, &sp, &region);
      b = barrier(depth.Get(), D3D12_RESOURCE_STATE_COPY_DEST,
                  D3D12_RESOURCE_STATE_COPY_SOURCE);
      list->ResourceBarrier(1, &b);
      list->CopyTextureRegion(&rp, 0, 0, 0, &dp, nullptr);
      dp = plane(depth.Get(), 0);
      rp = placed(readback.Get(), fps[0]);
      list->CopyTextureRegion(&rp, 0, 0, 0, &dp, nullptr);
      check(list->Close(), "close2");
      queue->ExecuteCommandLists(1, lists);
      check(queue->Signal(fence.Get(), 2), "signal2");
      check(fence->SetEventOnCompletion(2, event), "event2");
      if (WaitForSingleObject(event, 10000) != WAIT_OBJECT_0)
        return 5;
      CloseHandle(event);
      check(readback->Map(0, nullptr, &mapped), "readback2");
      for (UINT y = 0; y < 37; y++)
        for (UINT x = 0; x < 63; x++) {
          if (*((std::uint8_t *)mapped + fps[1].Offset +
                y * fps[1].Footprint.RowPitch + x) !=
              ((x >= 11 && x < 39 && y >= 7 && y < 23)
                   ? std::uint8_t(x * 3 + y * 7)
                   : 0x5a)) {
            std::puts("FAIL partial R8 to stencil");
            return 6;
          }
          std::uint32_t z = 0;
          std::memcpy(&z,
                      (char *)mapped + fps[0].Offset +
                          y * fps[0].Footprint.RowPitch + x * 4,
                      4);
          if (z != (fmt == DXGI_FORMAT_R32G8X24_TYPELESS ? 0x3f000000
                                                         : 0x00800000)) {
            std::puts("FAIL depth changed");
            return 7;
          }
        }
      readback->Unmap(0, nullptr);
      std::puts("PASS partial stencil copy: inside pattern exact, outside "
                "unchanged, depth unchanged");
      check(alloc->Reset(), "reset next");
      check(list->Reset(alloc.Get(), nullptr), "reset list next");
    }
    check(list->Close(), "close final");
    check(device->GetDeviceRemovedReason(), "device status");
    if (validated) {
      ComPtr<ID3D12InfoQueue> info;
      check(device.As(&info), "info queue");
      UINT64 n = info->GetNumStoredMessagesAllowedByRetrievalFilter();
      for (UINT64 i = 0; i < n; i++) {
        SIZE_T len = 0;
        info->GetMessage(i, nullptr, &len);
        std::vector<char> data(len);
        auto *m = (D3D12_MESSAGE *)data.data();
        check(info->GetMessage(i, m, &len), "debug message");
        if (m->Severity <= D3D12_MESSAGE_SEVERITY_ERROR) {
          std::printf("FAIL debug validation: %s\n", m->pDescription);
          return 8;
        }
      }
      std::puts("PASS debug layer: no errors");
    }
    return 0;
  } catch (...) {
    return 1;
  }
}
