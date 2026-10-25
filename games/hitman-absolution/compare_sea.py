"""Compare exact sea-shader depth variants in a capture; never installs a fix."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import traceback
import renderdoc as rd

root = Path(os.environ['HITMAN_ANALYSIS_ROOT'])
capture_path = Path(os.environ['HITMAN_ANALYSIS_CAPTURE'])
source = Path(os.environ['HITMAN_ANALYSIS_SOURCE'])
diagnostic_dir = Path(os.environ['HITMAN_DIAGNOSTIC_ROOT'])
sys.path.insert(0, str(diagnostic_dir))
from hitman_depth_variant import with_depth_bias

capture = controller = feedback = replacement = shader = None
feedback_original = None
POINTS = ((820,335),(820,336),(760,354),(760,355),(705,373),(705,374),(710,394),(710,395))


def log(message):
    with (root/'analysis.log').open('a',encoding='utf-8') as out:
        out.write(time.strftime('%H:%M:%S')+' '+message+'\n')


def encode(value, depth=0):
    if value is None or isinstance(value,(bool,int,float,str)): return value
    if isinstance(value,rd.ResourceId): return str(value)
    if depth>=16: raise ValueError('Replay nesting limit')
    if isinstance(value,dict): return {str(k):encode(v,depth+1) for k,v in value.items()}
    if isinstance(value,(list,tuple)) or (hasattr(value,'__len__') and hasattr(value,'__getitem__')):
        return [encode(v,depth+1) for v in value]
    fields={}
    for key in dir(value):
        if key.startswith('_') or key in ('this','thisown'): continue
        v=getattr(value,key)
        if not callable(v): fields[key]=encode(v,depth+1)
    return fields if fields else str(value)


def write_json(name,value):
    (root/name).write_text(json.dumps(encode(value),indent=2),encoding='utf-8')


def snapshot(name):
    result={'name':name,'pixels':[]}
    for event,suffix in ((18792,'ein-draw'),(18836,'wasser')):
        controller.SetFrameEvent(event,True)
        save=rd.TextureSave();save.resourceId=hdr;save.destType=rd.FileType.PNG;save.mip=0
        status=controller.SaveTexture(save,str(root/(name+'-'+suffix+'.png')))
        if status.code!=rd.ResultCode.Succeeded: raise RuntimeError('Image export failed: '+str(status))
        if event==18792:
            for x,y in POINTS:
                value=controller.PickPixel(hdr,x,y,rd.Subresource(),rd.CompType.Typeless)
                result['pixels'].append({'x':x,'y':y,'rgba':list(value.floatValue)})
    return result


try:
    if capture_path.name!='Hitman_frame2683.rdc' or capture_path.stat().st_size!=443524054:
        raise RuntimeError('Expected the previously inspected sea capture')
    expected=(source/'shaders/ResourceId824.dxil').read_bytes()
    if len(expected)!=32152 or expected[4:20].hex()!='4f16d76e2ccbec2118771808f68848fa':
        raise RuntimeError('Captured shader does not match the sea pass')
    feedback=rd.SetConfigSetting('D3D12.BindlessFeedback')
    if feedback is None: raise RuntimeError('BindlessFeedback setting unavailable')
    feedback_original=feedback.AsBool();feedback.data.basic.b=False
    rd.SetDebugLogFile(str(root/'renderdoc.log'))
    capture=rd.OpenCaptureFile();status=capture.OpenFile(str(capture_path),'',None)
    if status.code!=rd.ResultCode.Succeeded: raise RuntimeError(str(status))
    status,controller=capture.OpenCapture(rd.ReplayOptions(),None)
    if status.code!=rd.ResultCode.Succeeded or controller is None: raise RuntimeError(str(status))
    textures={str(t.resourceId):t.resourceId for t in controller.GetTextures()}
    hdr=textures['ResourceId::8520']
    controller.SetFrameEvent(18792,True)
    reflection=controller.GetPipelineState().GetShaderReflection(rd.ShaderStage.Pixel)
    shader=reflection.resourceId
    if str(shader)!='ResourceId::824' or bytes(reflection.rawBytes)!=expected:
        raise RuntimeError('Active sea shader differs from native inventory')
    log('Original und ungeaenderte LLVM-Kontrolle; danach Tiefenvarianten nur im Replay.')
    results=[snapshot('original')]
    # Choose measured black stripe pixels and immediately adjacent intact ones.
    for x,y in POINTS:
        log('Streifen-Pixelhistorie %d,%d' % (x,y))
        history=list(controller.PixelHistory(hdr,x,y,rd.Subresource(),rd.CompType.Typeless))
        write_json('history-%d-%d.json' % (x,y),history)
    shader_file=root/'sea-original.dxil';shader_file.write_bytes(expected)
    original_ir=root/'sea-original.ll'
    compiler=diagnostic_dir/'Shader-Compiler/dxc.exe'
    assembler=diagnostic_dir/'Shader-Compiler/DxilAssemble.exe'
    if not compiler.is_file() or not assembler.is_file(): raise RuntimeError('DXIL toolchain missing')
    with (root/'compiler.log').open('w',encoding='utf-8') as out:
        status=subprocess.run([str(compiler),'-dumpbin','-Fc',str(original_ir),str(shader_file)],stdout=out,stderr=subprocess.STDOUT,timeout=60)
    if status.returncode: raise RuntimeError('DXIL LLVM export failed; see compiler.log')
    original=original_ir.read_text(encoding='utf-8')
    if rd.ShaderEncoding.DXBC not in list(controller.GetTargetShaderEncodings()):
        raise RuntimeError('DXIL replay replacement unavailable')
    for name,bias in (('llvm-control',None),('depth-zero',0),('depth-plus-4',4),('depth-plus-64',64),('depth-plus-512',512),('depth-plus-8192',8192)):
        log('Vergleiche '+name)
        ir=root/(name+'.ll'); binary=root/(name+'.dxil')
        ir.write_text(original if bias is None else with_depth_bias(original,bias),encoding='utf-8')
        with (root/(name+'-compiler.log')).open('w',encoding='utf-8') as out:
            status=subprocess.run([str(assembler),str(ir),str(binary)],stdout=out,stderr=subprocess.STDOUT,timeout=60)
        if status.returncode or not binary.is_file(): raise RuntimeError('DXIL assembly failed: '+name)
        replacement,errors=controller.BuildTargetShader('main',rd.ShaderEncoding.DXBC,binary.read_bytes(),rd.ShaderCompileFlags(),rd.ShaderStage.Pixel)
        if replacement==rd.ResourceId.Null(): raise RuntimeError('Replay shader failed: '+str(errors))
        controller.ReplaceResource(shader,replacement)
        controller.SetFrameEvent(18792,True)
        if controller.GetPipelineState().GetShaderReflection(rd.ShaderStage.Pixel).resourceId!=replacement:
            raise RuntimeError('Replacement shader is not active')
        result=snapshot(name)
        result['identicalToOriginal']={suffix:(root/(name+'-'+suffix+'.png')).read_bytes()==(root/('original-'+suffix+'.png')).read_bytes() for suffix in ('ein-draw','wasser')}
        result['shaderSha256']=hashlib.sha256(binary.read_bytes()).hexdigest()
        results.append(result);write_json('comparison.json',results)
        if bias is None and not all(result['identicalToOriginal'].values()):
            raise RuntimeError('Unmodified LLVM reassembly changed the image; comparison is invalid')
        controller.RemoveReplacement(shader);controller.FreeTargetResource(replacement);replacement=None
    write_json('result.json',{'success':True,'capture':str(capture_path),'variants':len(results)})
    log('FERTIG: Streifen-Pixelhistorien und kontrollierte Tiefenvergleiche gespeichert. Nichts installiert.')
except Exception:
    error=traceback.format_exc();log(error);write_json('result.json',{'success':False,'error':error})
finally:
    if controller is not None:
        try:
            if replacement is not None:
                try: controller.RemoveReplacement(shader)
                finally: controller.FreeTargetResource(replacement)
        finally: controller.Shutdown()
    if capture is not None: capture.Shutdown()
    if feedback is not None and feedback_original is not None: feedback.data.basic.b=feedback_original
raise SystemExit(0)
