"""Export scene images and actual bindless texture inputs from a prior replay.

Read-only RenderDoc pass: no shader replacement, game boot or config write.
Run on the capture's Windows GPU through inspect_inputs.ps1.
"""
import json
import os
from pathlib import Path
import struct
import time
import traceback
import renderdoc as rd

root = Path(os.environ['HITMAN_ANALYSIS_ROOT'])
source = Path(os.environ['HITMAN_ANALYSIS_SOURCE'])
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
        raise ValueError('Replay nesting limit exceeded')
    if isinstance(value, dict):
        return {str(k): encode(v, depth + 1) for k, v in value.items()}
    if isinstance(value, (list, tuple)) or (hasattr(value, '__len__') and hasattr(value, '__getitem__')):
        return [encode(item, depth + 1) for item in value]
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


def image(rid, name):
    save = rd.TextureSave()
    save.resourceId = rid
    save.destType = rd.FileType.PNG
    save.mip = 0
    status = controller.SaveTexture(save, str(root / (name + '.png')))
    if status.code != rd.ResultCode.Succeeded:
        raise RuntimeError('Texture export failed: %s: %s' % (name, status))


try:
    inventory = json.loads((source / 'result.json').read_text(encoding='utf-8'))
    if not inventory.get('success') or Path(inventory['capture']) != capture_path:
        raise RuntimeError('Prior analysis does not match this capture')
    records = [json.loads(line) for line in (source / 'scene-draws.jsonl').read_text(encoding='utf-8').splitlines()]
    by_event = {record['event']: record for record in records}
    # For each scene buffer find its first actual draw at a sampled sea pixel.
    # Native states in the prior pass were collected before PixelHistory.
    selected = set()
    targets = set()
    for path in sorted(source.glob('history-*.json')):
        history = json.loads(path.read_text(encoding='utf-8'))
        candidates = [item['eventId'] for item in history
                      if item['eventId'] in by_event and item['shaderOut']['depth'] >= 0
                      and not item['depthTestFailed'] and not item['shaderDiscarded']]
        if candidates:
            selected.add(min(candidates))
            targets.add(path.name.split('-')[1])
    if not selected or len(selected) > 16:
        raise RuntimeError('Expected a small set of sampled sea draws, found %d' % len(selected))
    feedback = rd.SetConfigSetting('D3D12.BindlessFeedback')
    if feedback is None:
        raise RuntimeError('BindlessFeedback setting unavailable')
    feedback_original = feedback.AsBool()
    feedback.data.basic.b = False
    rd.SetDebugLogFile(str(root / 'renderdoc.log'))
    capture = rd.OpenCaptureFile()
    status = capture.OpenFile(str(capture_path), '', None)
    if status.code != rd.ResultCode.Succeeded:
        raise RuntimeError(str(status))
    status, controller = capture.OpenCapture(rd.ReplayOptions(), None)
    if status.code != rd.ResultCode.Succeeded or controller is None:
        raise RuntimeError(str(status))
    textures = {t.resourceId: t for t in controller.GetTextures()}
    stores = list(controller.GetDescriptorStores())
    write_json('textures.json', list(textures.values()))
    (root / 'buffers').mkdir()
    snapshots = []
    for event in sorted(selected):
        log('Meer-Draw %d: Zwischenbilder, Konstanten und echte Heap-Texturen.' % event)
        controller.SetFrameEvent(event, True)
        pipe = controller.GetPipelineState()
        native = controller.GetD3D12PipelineState()
        snapshot = {'event': event, 'outputs': list(pipe.GetOutputTargets()), 'stages': {}}
        for target in pipe.GetOutputTargets():
            if target.resource in textures:
                image(target.resource, 'draw-%d-%s' % (event, str(target.resource).replace('::', '')))
        for stage in (rd.ShaderStage.Vertex, rd.ShaderStage.Pixel):
            reflection = pipe.GetShaderReflection(stage)
            if reflection is None:
                continue
            stage_name = str(stage).split('.')[-1]
            constants = list(pipe.GetConstantBlocks(stage, True))
            resources = list(pipe.GetReadOnlyResources(stage, True))
            stage_info = {'shader': reflection.resourceId, 'constants': constants,
                          'resources': resources, 'bindings': list(reflection.readOnlyResources),
                          'heapInputs': []}
            snapshot['stages'][str(stage)] = stage_info
            for block in constants:
                desc = block.descriptor
                if not desc.byteSize:
                    continue
                data = bytes(controller.GetBufferData(desc.resource, desc.byteOffset, min(int(desc.byteSize), 16384)))
                (root / 'buffers' / ('%d-%s-cb%d.bin' % (event, stage_name, block.access.index))).write_bytes(data)
            texture_count = sum(binding.name.startswith('xe_texture') for binding in reflection.readOnlyResources)
            if not texture_count:
                continue
            bindless = [resource for resource in resources
                        if 0 <= resource.access.index < len(reflection.readOnlyResources)
                        and reflection.readOnlyResources[resource.access.index].name == 'bindless_data']
            if len(bindless) != 1:
                raise RuntimeError('Bindless index buffer not identified for %d %s' % (event, stage_name))
            desc = bindless[0].descriptor
            size = texture_count * 8
            data = bytes(controller.GetBufferData(desc.resource, desc.byteOffset, size))
            if len(data) != size:
                raise RuntimeError('Short bindless index buffer')
            (root / 'buffers' / ('%d-%s-bindless.bin' % (event, stage_name))).write_bytes(data)
            indices = [struct.unpack_from('<I', data, i * 8)[0] for i in range(texture_count)]
            heaps = [store for store in stores if store.resourceId in native.descriptorHeaps
                     and store.descriptorCount > max(indices)]
            if not heaps:
                raise RuntimeError('Bound descriptor heap not found')
            for store in heaps:
                ranges = []
                for index in sorted(set(indices)):
                    region = rd.DescriptorRange()
                    region.offset = store.firstDescriptorOffset + index * store.descriptorByteSize
                    region.descriptorSize = store.descriptorByteSize
                    region.count = 1
                    ranges.append(region)
                descriptors = list(controller.GetDescriptors(store.resourceId, ranges))
                if len(descriptors) != len(ranges):
                    raise RuntimeError('Descriptor count mismatch')
                for index, descriptor in zip(sorted(set(indices)), descriptors):
                    if descriptor.resource not in textures:
                        continue
                    name = 'draw-%d-%s-heap%d-%s' % (event, stage_name, index, str(descriptor.resource).replace('::', ''))
                    stage_info['heapInputs'].append({'index': index, 'store': store.resourceId,
                                                    'descriptor': descriptor, 'image': name + '.png'})
                    image(descriptor.resource, name)
            if not stage_info['heapInputs']:
                raise RuntimeError('No actual textures resolved from bindless indices')
        snapshots.append(snapshot)
        write_json('sea-inputs.json', snapshots)
    # Also export each scene buffer after its final draw, before later clearing.
    for target in sorted(targets):
        events = [record['event'] for record in records
                  if any(output['resource'].replace('::', '') == target for output in record['outputs'])]
        if not events:
            continue
        event = max(events)
        controller.SetFrameEvent(event, True)
        rid = next(rid for rid in textures if str(rid).replace('::', '') == target)
        image(rid, 'scene-end-%d-%s' % (event, target.replace('::', '')))
    write_json('result.json', {'success': True, 'capture': str(capture_path),
                              'source': str(source), 'seaEvents': sorted(selected)})
    log('FERTIG: Meer-Eingaben und Zwischenbilder gespeichert; keine Spielaenderung.')
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
