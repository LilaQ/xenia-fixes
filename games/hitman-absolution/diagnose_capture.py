"""Inspect scene draw states and water pixel histories; never changes the game.

Run using RenderDoc's --python with HITMAN_ANALYSIS_CAPTURE/ROOT set.
Native pipeline snapshots are deliberately collected BEFORE PixelHistory,
which instruments replay pipelines. No resource replacement is performed.
"""
import hashlib
import collections
import json
import os
from pathlib import Path
import time
import traceback
import renderdoc as rd

root = Path(os.environ['HITMAN_ANALYSIS_ROOT'])
capture_path = Path(os.environ['HITMAN_ANALYSIS_CAPTURE'])
controller = capture = feedback = None
feedback_original = None


def log(message):
    with (root / 'analysis.log').open('a', encoding='utf-8') as output:
        output.write(time.strftime('%H:%M:%S') + ' ' + message + '\n')


def encode(value, depth=0):
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    if isinstance(value, rd.ResourceId):
        return str(value)
    if isinstance(value, (bytes, bytearray)):
        return {'bytes': len(value)}
    if depth >= 16:
        raise ValueError('Replay state nesting exceeded diagnostic limit')
    if isinstance(value, dict):
        return {str(k): encode(v, depth + 1) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [encode(item, depth + 1) for item in value]
    if hasattr(value, '__len__') and hasattr(value, '__getitem__'):
        return [encode(value[i], depth + 1) for i in range(len(value))]
    fields = {}
    for name in dir(value):
        if name.startswith('_') or name in ('this', 'thisown'):
            continue
        item = getattr(value, name)
        if not callable(item):
            fields[name] = encode(item, depth + 1)
    return fields if fields else str(value)


def write_json(name, value):
    (root / name).write_text(json.dumps(encode(value), indent=2), encoding='utf-8')


def flatten(actions):
    result = []
    for action in actions:
        result.append(action)
        result.extend(flatten(action.children))
    return result


try:
    rd.SetDebugLogFile(str(root / 'renderdoc.log'))
    feedback = rd.SetConfigSetting('D3D12.BindlessFeedback')
    if feedback is None:
        raise RuntimeError('RenderDoc BindlessFeedback setting is unavailable')
    feedback_original = feedback.AsBool()
    feedback.data.basic.b = False
    if feedback.AsBool():
        raise RuntimeError('Bindless instrumentation could not be disabled')
    log('Oeffne Meer-Aufnahme; kein Spielstart und keine Config-Aenderung.')
    capture = rd.OpenCaptureFile()
    status = capture.OpenFile(str(capture_path), '', None)
    if status.code != rd.ResultCode.Succeeded:
        raise RuntimeError(str(status))
    status, controller = capture.OpenCapture(rd.ReplayOptions(), None)
    if status.code != rd.ResultCode.Succeeded or controller is None:
        raise RuntimeError(str(status))
    actions = flatten(controller.GetRootActions())
    draws = [a for a in actions if a.flags & rd.ActionFlags.Drawcall]
    textures = {t.resourceId: t for t in controller.GetTextures()}
    write_json('textures.json', list(textures.values()))
    write_json('actions.json', [{'event': a.eventId, 'flags': str(a.flags),
                                'outputs': list(a.outputs), 'depth': a.depthOut}
                               for a in actions])
    # Select scene buffers from the actual captured draw outputs, not fixed IDs.
    scene_ids = {rid for a in draws for rid in a.outputs if rid in textures
                 and textures[rid].width == 1280 and textures[rid].height >= 720
                 and textures[rid].format.compType == rd.CompType.Float
                 and textures[rid].format.compCount == 4}
    hdr_events = [a.eventId for a in draws if any(rid in scene_ids for rid in a.outputs)]
    if hdr_events:
        early_counts = collections.Counter(
            rid for a in draws if a.eventId < min(hdr_events) for rid in a.outputs
            if rid in textures and textures[rid].width == 1280
            and textures[rid].height >= 720
            and textures[rid].format.compType == rd.CompType.UNorm
            and textures[rid].format.compCount == 4)
        # Deferred scene buffers precede HDR lighting. Inspect the three most
        # used MRTs too: artifacts there survive into HDR without an HDR Z fail.
        scene_ids.update(rid for rid, count in early_counts.most_common(3))
    scene_draws = [a for a in draws if any(rid in scene_ids for rid in a.outputs)]
    if not scene_draws:
        raise RuntimeError('No scene HDR draw calls found in this capture')
    log('%d Szenen-Draws: native Pipeline-Zustaende vor der Pixelhistorie.' % len(scene_draws))
    shader_dir = root / 'shaders'
    shader_dir.mkdir()
    seen = set()
    with (root / 'scene-draws.jsonl').open('w', encoding='utf-8') as output:
        for index, action in enumerate(scene_draws):
            controller.SetFrameEvent(action.eventId, True)
            pipe = controller.GetPipelineState()
            native = controller.GetD3D12PipelineState()
            record = {'event': action.eventId, 'pipeline': pipe.GetGraphicsPipelineObject(),
                      'outputs': list(pipe.GetOutputTargets()), 'depth': pipe.GetDepthTarget(),
                      'rasterizer': native.rasterizer.state,
                      'viewports': list(native.rasterizer.viewports),
                      'depthStencil': native.outputMerger.depthStencilState,
                      'blends': list(native.outputMerger.blendState.blends),
                      'blendFactor': list(native.outputMerger.blendState.blendFactor),
                      'stages': {}}
            for stage in (rd.ShaderStage.Vertex, rd.ShaderStage.Pixel):
                reflection = pipe.GetShaderReflection(stage)
                if reflection is None:
                    continue
                shader = reflection.resourceId
                raw = bytes(reflection.rawBytes)
                if not raw:
                    raise RuntimeError('Captured shader bytecode unavailable: ' + str(shader))
                record['stages'][str(stage)] = {'shader': shader,
                    'byteLength': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(),
                    'dxbcDigest': raw[4:20].hex() if raw[:4] == b'DXBC' else None,
                    'inputSignature': list(reflection.inputSignature),
                    'outputSignature': list(reflection.outputSignature)}
                if shader not in seen:
                    filename = ''.join(c for c in str(shader) if c.isalnum())
                    (shader_dir / (filename + '.dxil')).write_bytes(raw)
                    text = controller.DisassembleShader(pipe.GetGraphicsPipelineObject(), reflection, '')
                    (shader_dir / (filename + '.txt')).write_text(text, encoding='utf-8')
                    seen.add(shader)
            output.write(json.dumps(encode(record)) + '\n')
            if index % 100 == 0:
                output.flush()
                log('Szenen-Draws: %d/%d' % (index + 1, len(scene_draws)))
    # All native state data is now saved. PixelHistory may instrument its own PSOs.
    for rid in sorted(scene_ids, key=str):
        name = ''.join(c for c in str(rid) if c.isalnum())
        for x, y in ((800, 355), (810, 356), (700, 360), (920, 355)):
            log('Meer-Pixelhistorie %s bei %d,%d' % (rid, x, y))
            history = list(controller.PixelHistory(rid, x, y, rd.Subresource(), rd.CompType.Typeless))
            write_json('history-%s-%d-%d.json' % (name, x, y), history)
    write_json('result.json', {'success': True, 'capture': str(capture_path),
                              'sceneDraws': len(scene_draws), 'shaders': len(seen)})
    log('FERTIG: Meer-Renderzustaende und Pixelhistorien gespeichert.')
except Exception:
    error = traceback.format_exc()
    log(error)
    write_json('result.json', {'success': False, 'error': error})
finally:
    if controller is not None:
        controller.Shutdown()
    if capture is not None:
        capture.Shutdown()
    if feedback is not None and feedback_original is not None:
        feedback.data.basic.b = feedback_original
raise SystemExit(0)
