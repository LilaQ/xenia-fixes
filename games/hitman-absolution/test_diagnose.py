"""Check replay ordering, structured state output and cleanup without a GPU."""
import json
import os
from pathlib import Path
import runpy
import sys
import tempfile
import types


class ResourceId:
    def __init__(self, value): self.value = value
    def __str__(self): return 'ResourceId::' + str(self.value)
    def __hash__(self): return hash(self.value)
    def __eq__(self, other): return isinstance(other, ResourceId) and self.value == other.value


def check(scenario):
    with tempfile.TemporaryDirectory(prefix='hitman-capture-test-') as directory:
        root = Path(directory)
        os.environ['HITMAN_ANALYSIS_ROOT'] = str(root)
        os.environ['HITMAN_ANALYSIS_CAPTURE'] = str(root / 'input.rdc')
        n = types.SimpleNamespace
        status = n(code=0)
        setting = n(data=n(basic=n(b=True)))
        setting.AsBool = lambda: setting.data.basic.b
        closed = []
        scene = ResourceId(10)
        shader = ResourceId(20)
        depth = ResourceId(30)
        texture = n(resourceId=scene, width=1280, height=2048,
                    format=n(compType=1, compCount=4))
        action = n(eventId=100, flags=1, outputs=[scene], depthOut=depth, children=[])
        actions, textures = [action], [texture]
        if scenario == 'early-gbuffer':
            early = ResourceId(11)
            textures.append(n(resourceId=early, width=1280, height=2048,
                              format=n(compType=2, compCount=4)))
            actions.insert(0, n(eventId=50, flags=1, outputs=[early], depthOut=depth, children=[]))
        blend = n(enabled=True, colorBlend=n(source=2, destination=3), writeMask=15)
        native = n(rasterizer=n(state=n(depthBias=0, slopeScaledDepthBias=0.0), viewports=[]),
                   outputMerger=n(depthStencilState=n(depthEnable=True, depthWrites=True, depthFunction=6),
                                  blendState=n(blends=[blend], blendFactor=[1.0]*4)))
        reflection = n(resourceId=shader, rawBytes=b'DXBC' + bytes(range(16)),
                       inputSignature=[], outputSignature=[])
        pipe = n(GetGraphicsPipelineObject=lambda: ResourceId(40),
                 GetOutputTargets=lambda: [n(resource=scene)],
                 GetDepthTarget=lambda: n(resource=depth),
                 GetShaderReflection=lambda stage: reflection if stage == 1 else None)
        if scenario == 'no-bytecode': reflection.rawBytes = b''
        def history(*args):
            # PixelHistory must never run before the uninstrumented state export.
            records = [json.loads(line) for line in (root / 'scene-draws.jsonl').read_text().splitlines()]
            assert records[0]['blends'][0]['colorBlend']['source'] == 2
            assert records[0]['depthStencil']['depthWrites'] is True
            if scenario == 'history-failure': raise RuntimeError('synthetic replay failure')
            return [n(eventId=100, depthTestFailed=True, preMod=n(depth=0.5), shaderOut=n(depth=0.4))]
        controller = n(GetRootActions=lambda: actions, GetTextures=lambda: [] if scenario == 'no-scene' else textures,
                       SetFrameEvent=lambda *args: None, GetPipelineState=lambda: pipe,
                       GetD3D12PipelineState=lambda: native, DisassembleShader=lambda *args: 'synthetic shader',
                       PixelHistory=history, Shutdown=lambda: closed.append('controller'))
        capture = n(OpenFile=lambda *args: status, OpenCapture=lambda *args: (status, controller),
                    Shutdown=lambda: closed.append('capture'))
        module = types.ModuleType('renderdoc')
        for name, value in dict(ResourceId=ResourceId, SetDebugLogFile=lambda *args: None,
            SetConfigSetting=lambda *args: setting, OpenCaptureFile=lambda: capture,
            ResultCode=n(Succeeded=0), ReplayOptions=lambda: None, Subresource=lambda: None,
            CompType=n(Float=1, UNorm=2, Typeless=3), ActionFlags=n(Drawcall=1),
            ShaderStage=n(Vertex=0, Pixel=1)).items(): setattr(module, name, value)
        sys.modules['renderdoc'] = module
        try:
            runpy.run_path(str(Path(__file__).with_name('diagnose_capture.py')))
        except SystemExit as exit:
            assert exit.code == 0
        result = json.loads((root / 'result.json').read_text())
        success = scenario in ('success', 'early-gbuffer')
        assert result['success'] == success, result
        assert closed == ['controller', 'capture']
        assert setting.AsBool() is True
        assert not (root / 'input.rdc').exists()
        if success:
            assert len(list(root.glob('history-*.json'))) == (8 if scenario == 'early-gbuffer' else 4)
            assert result['sceneDraws'] == (2 if scenario == 'early-gbuffer' else 1)
            assert (root / 'shaders/ResourceId20.dxil').read_bytes() == reflection.rawBytes


for scenario in ('success', 'early-gbuffer', 'no-scene', 'no-bytecode', 'history-failure'):
    check(scenario)
print('PASS: early deferred buffers, replay ordering, structured states and failure cleanup in five scenarios.')
