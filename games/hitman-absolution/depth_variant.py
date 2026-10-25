"""Add a depth output to captured DXIL LLVM without changing its colour math."""
import re


def with_depth_bias(source, ulps):
    if not isinstance(ulps, int) or not 0 <= ulps <= 8192:
        raise ValueError('Unsupported depth bias')
    if 'water_bias_' in source or '!"SV_Depth"' in source:
        raise ValueError('Shader already has a depth output or this modification')
    definitions = {int(m[1]): m[2] for m in re.finditer(r'^!(\d+) = (.*)$', source, re.M)}
    def definition(index):
        try: return definitions[index]
        except KeyError: raise ValueError('Missing metadata node')
    entry = re.search(r'^!dx\.entryPoints = !\{!(\d+)\}$', source, re.M)
    if not entry:
        raise ValueError('Expected one DXIL entry point')
    main = re.fullmatch(r'!\{void \(\)\* @main, !"main", !(\d+), .*\}', definition(int(entry[1])))
    if not main:
        raise ValueError('Unexpected main metadata')
    signature = re.fullmatch(r'!\{!(\d+), !(\d+), (?:null|!\d+)\}', definition(int(main[1])))
    if not signature:
        raise ValueError('Unexpected signature metadata')
    input_list, output_list = map(int, signature.groups())
    inputs = [int(v) for v in re.findall(r'!(\d+)', definition(input_list))]
    outputs = [int(v) for v in re.findall(r'!(\d+)', definition(output_list))]
    positions = [(node, re.fullmatch(r'!\{i32 (\d+), !"SV_Position", i8 9, i8 3, !(\d+), i8 \d+, i32 1, i8 4, i32 \d+, i8 0, !(\d+)\}', definition(node))) for node in inputs]
    positions = [(node, match) for node, match in positions if match]
    if len(positions) != 1 or not outputs:
        raise ValueError('Expected one float4 SV_Position input and colour outputs')
    node, position = positions[0]
    position_id, semantic_index, tags = map(int, position.groups())
    usage = definition(tags)
    if not re.search(r'i32 3, i8 \d+', usage):
        raise ValueError('SV_Position usage mask is absent')
    usage = re.sub(r'i32 3, i8 (\d+)', lambda m: 'i32 3, i8 ' + str(int(m[1]) | 4), usage)
    output_ids = []
    for index in outputs:
        match = re.match(r'!\{i32 (\d+),', definition(index))
        if not match: raise ValueError('Unexpected output element')
        output_ids.append(int(match[1]))
    depth_id = max(output_ids) + 1
    depth_node, usage_node, depth_usage_node = range(max(definitions) + 1, max(definitions) + 4)
    old_list = definition(output_list)
    if not old_list.endswith('}'):
        raise ValueError('Malformed output list')
    source = source.replace('!%d = %s' % (output_list, old_list),
                            '!%d = %s, !%d}' % (output_list, old_list[:-1], depth_node))
    old_position = definition(node)
    source = source.replace('!%d = %s' % (node, old_position),
                            '!%d = %s' % (node, old_position.replace('!%d}' % tags, '!%d}' % usage_node)))
    source += '\n!%d = %s\n' % (usage_node, usage)
    source += '!%d = !{i32 3, i8 1}\n' % depth_usage_node
    source += '!%d = !{i32 %d, !"SV_Depth", i8 9, i8 17, !%d, i8 0, i32 1, i8 1, i32 -1, i8 0, !%d}\n' % (depth_node, depth_id, semantic_index, depth_usage_node)
    code = f'  %water_bias_depth = call float @dx.op.loadInput.f32(i32 4, i32 {position_id}, i32 0, i8 2, i32 undef)\n'
    value = '%water_bias_depth'
    if ulps:
        code += '  %water_bias_bits = bitcast float %water_bias_depth to i32\n'
        code += f'  %water_bias_adjusted_bits = add i32 %water_bias_bits, {ulps}\n'
        code += '  %water_bias_adjusted_depth = bitcast i32 %water_bias_adjusted_bits to float\n'
        value = '%water_bias_adjusted_depth'
    code += f'  call void @dx.op.storeOutput.f32(i32 5, i32 {depth_id}, i32 0, i8 0, float {value})\n'
    if source.count('  ret void\n}') != 1:
        raise ValueError('Expected one main return')
    return source.replace('  ret void\n}', code + '  ret void\n}')
