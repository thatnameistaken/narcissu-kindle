"""Prepare head/tail silence for one-shot Bluetooth playback; preserve payload."""
from pathlib import Path
import argparse,collections,json,hashlib

def pad_audio(root):
    root=Path(root);media=json.loads((root/'media.json').read_text(encoding='utf-8'))
    usage=collections.defaultdict(set)
    for lang in ('en','ja'):
        for ev in json.loads((root/(lang+'.json')).read_text(encoding='utf-8'))['events']:
            if ev['op']=='audio':usage[ev['asset']].add(ev['loop'])
    count=0
    for key,m in media.items():
        if m['kind']!='audio' or usage[key]!={False}:continue
        if m.get('padding_revision')==1:count+=1;continue
        # Whole stereo frames only. Keep original content duration and digest.
        p=root/m['file'];payload=p.read_bytes();frame_bytes=m['channels']*2
        lead_frames=m['rate'];tail_frames=m['rate']*3//2
        m.update(padding_revision=1,lead_in=lead_frames/m['rate'],tail=tail_frames/m['rate'],
            payload_sha256=hashlib.sha256(payload).hexdigest(),payload_bytes=len(payload))
        temporary=p.with_suffix('.pcm.tmp')
        temporary.write_bytes(bytes(lead_frames*frame_bytes)+payload+bytes(tail_frames*frame_bytes))
        temporary.replace(p);count+=1
    (root/'media.json').write_text(json.dumps(media,ensure_ascii=False),encoding='utf-8')
    report_path=root/'build-report.json'
    if report_path.exists():
        report=json.loads(report_path.read_text(encoding='utf-8'))
        report['media']['bytes']=sum(p.stat().st_size for p in (root/'media').iterdir() if p.is_file())
        report['media']['padded_one_shots']=count
        report_path.write_text(json.dumps(report,indent=2),encoding='utf-8')
    print('One-shot audio files with Bluetooth head/tail silence:',count,flush=True)
    return count

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--data',required=True)
    pad_audio(parser.parse_args().data)
