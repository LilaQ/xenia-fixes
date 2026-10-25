"""Prepare, but do not apply, a Rise-only LaunchBox emulator association.

Apply only after the interactive fix succeeds and LaunchBox/Big Box are closed.
The complete existing Edge controls and Keys2Pad lifecycle are cloned; only
its process name and executable path change for this one game.
"""
import argparse,re,uuid
from pathlib import Path
import xml.etree.ElementTree as ET
FIX=str(uuid.uuid5(uuid.NAMESPACE_URL,'xenia-edge-rise-pixel-fetch-residency'))
EXE='Emulators\\Xenia Edge\\xenia_edge_rise.exe'
TITLE='Xenia Edge - Rise pixel fetch fix'

def replace_text(block,tag,value):
 pattern=r'(<'+tag+r'>)([^<]*)(</'+tag+r'>)'
 out,count=re.subn(pattern,lambda m:m[1]+value+m[3],block)
 if count!=1:raise ValueError('Unexpected XML field '+tag)
 return out

def prepare(lb,output,game_id,edge_id):
 ep=lb/'Data/Emulators.xml';gp=lb/'Data/Platforms/Microsoft Xbox 360.xml'
 ebytes=ep.read_bytes();gbytes=gp.read_bytes();eroot=ET.fromstring(ebytes);groot=ET.fromstring(gbytes)
 base=next(e for e in eroot.findall('Emulator') if e.findtext('ID')==edge_id)
 game=next(g for g in groot.findall('Game') if g.findtext('ID')==game_id)
 if game.findtext('Emulator')!=edge_id:raise ValueError('Rise association changed; reassess before preparing')
 if any(e.findtext('ID')==FIX for e in eroot.findall('Emulator')):raise ValueError('Fix emulator already exists')
 if not (lb/EXE.replace('\\','/')).is_file():raise ValueError('Fixed executable missing')
 et=ebytes.decode('utf-8-sig');gt=gbytes.decode('utf-8-sig')
 block=next(m.group() for m in re.finditer(r'<Emulator>.*?</Emulator>',et,re.S) if ET.fromstring(m.group()).findtext('ID')==edge_id)
 new=replace_text(block,'ID',FIX);new=replace_text(new,'ApplicationPath',EXE);new=replace_text(new,'Title',TITLE)
 new=new.replace('xenia_edge.exe','xenia_edge_rise.exe')
 # Preserve all quotes, indentation, unrelated entries, and newline conventions.
 closing=et.rfind('</LaunchBox>')
 if closing<0:raise ValueError('Unexpected root element')
 newline='\r\n' if '\r\n' in et else '\n'
 new_et=et[:closing]+'  '+new+newline+et[closing:]
 block=next(m.group() for m in re.finditer(r'<Game>.*?</Game>',gt,re.S) if ET.fromstring(m.group()).findtext('ID')==game_id)
 new=replace_text(block,'Emulator',FIX);new_gt=gt.replace(block,new,1)
 eout=new_et.encode('utf-8');gout=new_gt.encode('utf-8')
 changed=ET.fromstring(gout);after=next(g for g in changed.findall('Game') if g.findtext('ID')==game_id)
 assert len(changed.findall('Game'))==len(groot.findall('Game'))
 assert after.findtext('ApplicationPath')==game.findtext('ApplicationPath')
 assert after.findtext('CommandLine')==game.findtext('CommandLine')
 assert [g.findtext('ID') for g in changed.findall('Game')]==[g.findtext('ID') for g in groot.findall('Game')]
 clone=next(e for e in ET.fromstring(eout).findall('Emulator') if e.findtext('ID')==FIX)
 for tag in ['AutoHotkeyScript','ExitAutoHotkeyScript']:
  assert clone.findtext(tag)==base.findtext(tag).replace('xenia_edge.exe','xenia_edge_rise.exe')
 assert clone.findtext('AutoHotkeyScript').count('-WatchProcess xenia_edge_rise.exe')==1
 assert 'Process, Exist, xenia_edge_rise.exe' in clone.findtext('AutoHotkeyScript')
 # All existing emulator entries retain their original parsed content.
 originals=ET.fromstring(eout).findall('Emulator')
 for e in eroot.findall('Emulator'):
  match=next(x for x in originals if x.findtext('ID')==e.findtext('ID'))
  assert ET.tostring(match)==ET.tostring(e)
 output.mkdir(parents=True,exist_ok=True)
 (output/'Emulators.xml').write_bytes(eout);(output/'Microsoft Xbox 360.xml').write_bytes(gout)
 print('Prepared Rise-only association',FIX,'with unchanged game IDs/count and Keys2Pad/exit behavior')

if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--launchbox',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--game-id',required=True);p.add_argument('--edge-id',required=True);a=p.parse_args();prepare(a.launchbox,a.output,a.game_id,a.edge_id)
