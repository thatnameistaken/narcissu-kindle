"""Apply a small, lossless-PCM voice gain after padding (requires NumPy)."""
from pathlib import Path
import argparse,hashlib,json
import numpy as np

def boost_voices(root):
    root=Path(root)
    media=json.loads((root/'media.json').read_text(encoding='utf-8'))
    gain_db=1.5;gain=10**(gain_db/20);count=0
    for m in media.values():
        if m['kind']!='audio' or not m['original'].startswith('w/'):continue
        if m.get('voice_gain_db')==gain_db:count+=1;continue
        if 'voice_gain_db' in m:raise ValueError('Rebuild from originals before changing voice gain')
        path=root/m['file'];raw=path.read_bytes()
        head=round(m.get('lead_in',0)*m['rate'])*m['channels']*2
        tail=round(m.get('tail',0)*m['rate'])*m['channels']*2
        end=len(raw)-tail;payload=raw[head:end]
        assert hashlib.sha256(payload).hexdigest()==m['payload_sha256']
        samples=np.frombuffer(payload,dtype='<i2').astype(np.float64)
        samples=np.rint(samples*gain)
        # Refuse clipping rather than silently distort any original voice.
        assert samples.min()>=-32768 and samples.max()<=32767,m['original']
        boosted=samples.astype('<i2').tobytes()
        temporary=path.with_suffix('.pcm.tmp')
        temporary.write_bytes(raw[:head]+boosted+raw[end:]);temporary.replace(path)
        m['original_payload_sha256']=m['payload_sha256']
        m['payload_sha256']=hashlib.sha256(boosted).hexdigest()
        m['voice_gain_db']=gain_db;count+=1
    (root/'media.json').write_text(json.dumps(media,ensure_ascii=False),encoding='utf-8')
    print('Voice assets boosted by 1.5 dB without clipping:',count,flush=True)
    return count

if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--data',required=True)
    boost_voices(ap.parse_args().data)
