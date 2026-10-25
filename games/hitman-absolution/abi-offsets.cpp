#include <d3d12.h>
#include <cstddef>
// Compile for Windows x64 to verify the API layout used by the continuation.
static_assert(sizeof(D3D12_GRAPHICS_PIPELINE_STATE_DESC) == 656);
static_assert(offsetof(D3D12_GRAPHICS_PIPELINE_STATE_DESC, PS) == 0x18);
static_assert(offsetof(D3D12_GRAPHICS_PIPELINE_STATE_DESC, DepthStencilState) == 0x1f0);
static_assert(offsetof(D3D12_DEPTH_STENCIL_DESC, DepthFunc) == 8);
static_assert(D3D12_COMPARISON_FUNC_GREATER_EQUAL == 7);

static_assert(offsetof(D3D12_GRAPHICS_PIPELINE_STATE_DESC, RasterizerState) + offsetof(D3D12_RASTERIZER_DESC, DepthBias) == 0x1d0);
static_assert(offsetof(D3D12_GRAPHICS_PIPELINE_STATE_DESC, RasterizerState) + offsetof(D3D12_RASTERIZER_DESC, DepthBiasClamp) == 0x1d4);
static_assert(offsetof(D3D12_GRAPHICS_PIPELINE_STATE_DESC, RasterizerState) + offsetof(D3D12_RASTERIZER_DESC, SlopeScaledDepthBias) == 0x1d8);
static_assert(offsetof(D3D12_GRAPHICS_PIPELINE_STATE_DESC, PrimitiveTopologyType) == 0x23c);
static_assert(offsetof(D3D12_GRAPHICS_PIPELINE_STATE_DESC, NumRenderTargets) == 0x240);
static_assert(offsetof(D3D12_GRAPHICS_PIPELINE_STATE_DESC, RTVFormats) == 0x244);
static_assert(offsetof(D3D12_GRAPHICS_PIPELINE_STATE_DESC, DSVFormat) == 0x264);
static_assert(offsetof(D3D12_GRAPHICS_PIPELINE_STATE_DESC, SampleDesc) == 0x268);
static_assert(DXGI_FORMAT_R16G16B16A16_FLOAT == 10);
static_assert(DXGI_FORMAT_D32_FLOAT_S8X24_UINT == 20);
static_assert(D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE == 3);
