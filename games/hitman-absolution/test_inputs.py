"""Check actual heap indexing, inventory matching and cleanup without a GPU."""
import json
import os
from pathlib import Path
import runpy
import struct
import sys
import tempfile
import types

class ResourceId:
    def __init__(self, value): self.value = value
    def __str__(self): return 'ResourceId::' + str(self.value)
    def __hash__(self): return hash(self.value)
    def __eq__(self, other): return isinstance(other, ResourceId) and self.value == other.value


def check(scenario):
    with tempfile.TemporaryDirectory(prefix='hitman-input-test-') as directory:
        root = Path(directory)
        source = root/'source'; source.mkdir()
        capture_path = root/'input.rdc'
        os.environ.update(HITMAN_ANALYSIS_ROOT=str(root), HITMAN_ANALYSIS_SOURCE=str(source),
                          HITMAN_ANALYSIS_CAPTURE=str(capture_path))
        (source/'result.json').write_text(json.dumps({'success': True,
            'capture': str(root/'wrong.rdc' if scenario == 'wrong-source' else capture_path)}))
        (source/'scene-draws.jsonl').write_text(json.dumps({'event': 10,
            'outputs': [{'resource': 'ResourceId::100'}]})+'\n')
        (source/'history-ResourceId100-800-355.json').write_text(json.dumps([{
            'eventId': 10, 'shaderOut': {'depth': 0.2}, 'depthTestFailed': False, 'shaderDiscarded': False}]))
        n=types.SimpleNamespace
        setting=n(data=n(basic=n(b=True))); setting.AsBool=lambda: setting.data.basic.b
        status=n(code=0)
        scene, shader, texture, buffer, heap = [ResourceId(i) for i in (100,200,300,400,500)]
        bindings=[n(name='bindless_data'), n(name='xe_texture0_2d_u'), n(name='xe_texture0_2d_s')]
        ro=[n(access=n(index=0), descriptor=n(resource=buffer,byteOffset=32))]
        if scenario == 'missing-bindless': ro=[]
        pipe=n(GetOutputTargets=lambda: [n(resource=scene)], GetShaderReflection=lambda stage:
            n(resourceId=shader,readOnlyResources=bindings) if stage==1 else None,
            GetReadOnlyResources=lambda *args:ro, GetConstantBlocks=lambda *args: [])
        calls=[]; closed=[]; images=[]
        def descriptors(store,ranges):
            assert store==heap
            # The actual index is 7, not the declaration's t-register or index-buffer offset.
            assert len(ranges)==1
            assert ranges[0].offset==80+7*32 and ranges[0].descriptorSize==32 and ranges[0].count==1
            calls.append('heap')
            return [n(resource=texture)]
        def buffer_data(resource,offset,length):
            assert resource==buffer and offset==32 and length==16
            return b'' if scenario=='short-indices' else struct.pack('<4I',7,0,7,0)
        def save(data,path):
            images.append((data.resourceId,Path(path).name))
            return n(code=1) if scenario=='image-failure' else status
        controller=n(GetTextures=lambda:[n(resourceId=scene),n(resourceId=texture)],
            GetDescriptorStores=lambda:[n(resourceId=heap,descriptorCount=64,descriptorByteSize=32,firstDescriptorOffset=80)],
            SetFrameEvent=lambda *args:None,GetPipelineState=lambda:pipe,
            GetD3D12PipelineState=lambda:n(descriptorHeaps=[heap]), GetBufferData=buffer_data,
            GetDescriptors=descriptors,SaveTexture=save, Shutdown=lambda:closed.append('controller'))
        capture=n(OpenFile=lambda *args:status,OpenCapture=lambda *args:(status,controller),
                  Shutdown=lambda:closed.append('capture'))
        module=types.ModuleType('renderdoc')
        for name,value in dict(ResourceId=ResourceId,SetConfigSetting=lambda *args:setting,
            SetDebugLogFile=lambda *args:None,OpenCaptureFile=lambda:capture,
            ResultCode=n(Succeeded=0),ReplayOptions=lambda:None,TextureSave=lambda:n(),
            FileType=n(PNG=1),ShaderStage=n(Vertex=0,Pixel=1),DescriptorRange=lambda:n()).items():
            setattr(module,name,value)
        sys.modules['renderdoc']=module
        try: runpy.run_path(str(Path(__file__).with_name('inspect_inputs.py')))
        except SystemExit as result: assert result.code==0
        result=json.loads((root/'result.json').read_text())
        assert result['success']==(scenario=='success'),result
        assert setting.AsBool() is True
        assert closed==([] if scenario=='wrong-source' else ['controller','capture'])
        assert not capture_path.exists()
        if scenario=='success':
            assert len(calls)==1 and len(images)==3
            assert images[-1][1]=='scene-end-10-ResourceId100.png'
            contents=json.loads((root/'sea-inputs.json').read_text())
            assert contents[0]['stages']['1']['heapInputs'][0]['index']==7
            assert (root/'buffers/10-1-bindless.bin').read_bytes()==struct.pack('<4I',7,0,7,0)

for scenario in ('success','wrong-source','missing-bindless','short-indices','image-failure'):
    check(scenario)
print('PASS: actual heap indices, scene ID normalization, mismatched captures, short buffers and cleanup.')
