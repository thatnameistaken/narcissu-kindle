#!/usr/bin/env python3
"""Build a personal Kindle installation from the original 2005 web editions.

Only the known voiced story route is compiled. Unknown commands fail the build.
The original scripts and asset archives remain intact in the source releases.
"""
from __future__ import annotations
import argparse, collections, hashlib, json, re, shutil, struct, subprocess, tarfile
from pathlib import Path

TITLES = {
 'en': ['Prologue','7F','The Silver Coupe','Map','The Emerald Sea','#1 Route','Echo','Narcissu','Shiraishi Construction'],
 'ja': ['プロローグ','７階','銀のクーペ','地図','エメラルドの海','一号線','エコー','ナルキッソス','白石工務店'],
}

def decode_script(data):
    return bytes(b ^ 0x84 for b in data).decode('cp932')

def compile_story(script, lang):
    lines=script.replace('\r\n','\n').splitlines()
    start=lines.index('*image_voice'); end=lines.index('*text_lb')
    events=[]; chapters=[]; pending=[]; clear=True; counts=collections.Counter()
    def emit(op, **kw): events.append(dict(op=op, **kw))
    def flush(boundary='\\'):
        nonlocal clear
        if pending:
            text='\n'.join(pending)
            # The Japanese chapter 8 source leaves a lone slash after an @.
            # Keep its event slot so existing saves retain their exact positions.
            if lang=='ja' and text=='/':emit('noop')
            else:emit('text', text=text, clear=clear)
            pending.clear()
            clear=boundary=='\\'
    for no in range(start,end):
        line=lines[no].strip()
        if not line or line.startswith(';'):continue
        # Script commands are ASCII. English normally uses a leading backtick;
        # this release also contains one unmarked quoted English utterance.
        if line.startswith('`') or ord(line[0])>127 or line.startswith('"'):
            if line.startswith('`'):line=line[1:]
            pieces=re.split(r'([@\\])',line)
            for i in range(0,len(pieces),2):
                part=pieces[i]
                if part:pending.append(part)
                if i+1<len(pieces):flush(pieces[i+1])
            continue
        if line.startswith('!'):
            if not re.fullmatch(r'!(?:s(?:d|\d+)|w\d+)',line):
                raise ValueError(f'{lang}:{no+1}: unknown text control {line}')
            if line.startswith('!w'):
                flush();emit('wait', ms=int(line[2:]))
            continue
        flush()
        command=line.split()[0]; counts[command]+=1
        if line.startswith('*'):
            chapter=len(chapters)+1
            if chapter>9:raise ValueError('Unexpected story label')
            chapters.append(dict(title=TITLES[lang][chapter-1],index=len(events)+1))
            emit('chapter',number=chapter,title=TITLES[lang][chapter-1]); clear=True
        elif command=='bg':
            m=re.fullmatch(r'bg\s+"([^"\n]+)"\s*,\s*\d+(?:,\d+)?',line)
            if not m:raise ValueError(f'Invalid bg: {line}')
            emit('image',file=m[1].replace('\\','/').lower())
        elif command in ('dwave','dwaveloop'):
            m=re.fullmatch(r'dwave(loop)?\s+(\d+),"([^"]+)"',line)
            if not m:raise ValueError(f'Invalid wave: {line}')
            emit('audio',channel='wave'+m[2],file=m[3].replace('\\','/').lower(),loop=bool(m[1]))
        elif command=='dwavestop':emit('stop',channel='wave'+line.split()[1])
        elif command in ('mp3','mp3loop'):
            m=re.fullmatch(r'mp3(?:loop)?\s+"([^"]+)"',line)
            if not m:raise ValueError(f'Invalid music: {line}')
            emit('audio',channel='music',file=m[1].replace('\\','/').lower(),loop=command=='mp3loop')
        elif command=='mp3fadeout':emit('fade',ms=int(line.split()[1]))
        elif command=='stop':emit('stop',channel='music')
        elif command=='wait':emit('wait',ms=int(line.split()[1]))
        elif command=='click':emit('click')
        elif command=='goto':
            dest=line.split()[1]
            if dest=='*honpen2_voice':pass # the following label
            elif dest=='*mini_title_voice':emit('chapter_end')
            elif dest=='*title':emit('end')
            else:raise ValueError(f'Unexpected branch {line}')
        elif command in ('setwindow','erasetextwindow'):
            pass # replaced by the fixed split-screen layout
        elif command=='mov':
            if not re.match(r'mov (?:\$sys_midasi|%flg_(?:pro|cha[2-9]|bplay)),',line):
                raise ValueError(f'Unexpected assignment {line}')
        else:raise ValueError(f'{lang}:{no+1}: unsupported story command: {line}')
    flush()
    if len(chapters)!=9 or not events or events[-1]['op']!='end':raise ValueError('Incomplete story')
    return dict(format=1,language=lang,chapters=chapters,events=events,
                source_sha256=hashlib.sha256(script.encode('utf-8')).hexdigest(),
                adaptation='2026-10-09: fixed split-screen layout; fades become scene cuts; chapter navigation replaces original menus. Story text unchanged.',
                counts=dict(counts))

class NSA:
    def __init__(self,path):
        self.data=Path(path).read_bytes();self.files={}
        count,self.base=struct.unpack_from('>HI',self.data);pos=6
        for _ in range(count):
            end=self.data.index(0,pos);name=self.data[pos:end].decode('cp932').replace('\\','/').lower();pos=end+1
            kind,offset,size,original=struct.unpack_from('>BIII',self.data,pos);pos+=13
            if self.base+offset+size>len(self.data):raise ValueError('Truncated NSA')
            if name.startswith('/') or '..' in name.split('/'):raise ValueError('Unsafe archive path')
            self.files[name]=(kind,self.base+offset,size,original)
    def read(self,name):
        kind,offset,size,_=self.files[name]
        data=self.data[offset:offset+size]
        if kind==1:return decode_spb(data)
        if kind!=0:raise ValueError(f'{name}: compressed NSA member type {kind} unsupported')
        return data

def decode_spb(data):
    """SPB planar delta/RLE image format; see ONScripter DirectReader.cpp.

    This implementation and the builder are distributed under GPL-2.0-or-later.
    """
    w,h=struct.unpack_from('>HH',data);bit=32
    if not 0<w<=8192 or not 0<h<=8192:raise ValueError('Invalid SPB dimensions')
    def read(n):
        nonlocal bit
        val=0
        for _ in range(n):
            val=(val<<1)|((data[bit//8]>>(7-bit%8))&1);bit+=1
        return val
    stride=(w*3+3)&~3;body=bytearray(stride*h)
    for channel in range(3):
        c=read(8);plane=[c]
        while len(plane)<w*h:
            n=read(3)
            if n==0:plane.extend([c]*4);continue
            bits=read(1)+1 if n==7 else n+2
            for _ in range(4):
                v=read(bits)
                c=v if bits==8 else (c+(v//2+1 if v&1 else -(v//2)))&255
                plane.append(c)
        for y in range(h):
            row=plane[y*w:(y+1)*w]
            if y%2:row.reverse()
            base=(h-1-y)*stride+channel
            body[base:base+w*3:3]=bytes(row)
    header=b'BM'+struct.pack('<IHHI',54+len(body),0,0,54)
    header+=struct.pack('<IiiHHIIiiII',40,w,h,1,24,0,len(body),0,0,0,0)
    return header+body

def source_dir(path, scratch):
    path=Path(path)
    if path.is_dir():return next(path.rglob('nscript.dat')).parent
    scratch.mkdir(parents=True,exist_ok=True)
    with tarfile.open(path) as t:t.extractall(scratch,filter='data')
    return next(scratch.rglob('nscript.dat')).parent

def build(en,ja,out,ffmpeg):
    from PIL import Image, ImageChops
    out=Path(out).resolve();out.mkdir(parents=True,exist_ok=True)
    media=out/'media';media.mkdir(exist_ok=True)
    display=out/'display';display.mkdir(exist_ok=True)
    scratch=out/'build-work';scratch.mkdir(exist_ok=True)
    manifest={};reports={};sources={}
    for lang,path in [('en',en),('ja',ja)]:
        root=source_dir(path,scratch/lang);sources[lang]=root
        story=compile_story(decode_script((root/'nscript.dat').read_bytes()),lang)
        archive=NSA(root/'arc.nsa')
        for ev in story['events']:
            if ev['op'] not in ('image','audio'):continue
            name=ev['file'];data=archive.read(name)
            key=hashlib.sha256(data).hexdigest()[:24]
            ev['asset']=key;del ev['file']
            if key in manifest:continue
            if ev['op']=='image':
                # Original JPEG bytes retained; the display scales at runtime.
                dest=media/(key+Path(name).suffix);dest.write_bytes(data)
                with Image.open(dest) as im:
                    w,h=im.size
                    rgb=im.convert('RGB')
                    # Remove only the outer letterbox, including a one-pixel
                    # encoding border in the original 800x600 backgrounds.
                    inner=rgb.crop((0,2,w,h-2))
                    bg=Image.new('RGB',inner.size,rgb.getpixel((0,0)))
                    mask=ImageChops.difference(inner,bg).convert('L').point(lambda p:255 if p>24 else 0)
                    box=mask.getbbox()
                    if box:
                        box=(0,max(0,box[1]+2-2),w,min(h,box[3]+2+2))
                        shown=rgb.crop(box)
                    else:shown=rgb
                    shown.save(display/(key+'.png'))
                manifest[key]=dict(kind='image',file='media/'+dest.name,display='display/'+key+'.png',width=w,height=h,original=name)
            else:
                src=scratch/(key+Path(name).suffix);src.write_bytes(data)
                # Decode at the source sample rate to stereo 16-bit PCM. No
                # lossy re-encoding and no dependence on Kindle MP3 codecs.
                wav=scratch/(key+'-decoded.wav')
                subprocess.run([ffmpeg,'-hide_banner','-loglevel','error','-y','-i',str(src),'-ac','2','-c:a','pcm_s16le',str(wav)],check=True)
                import wave
                with wave.open(str(wav),'rb') as f:
                    rate=f.getframerate();frames=f.getnframes();pcm=f.readframes(frames)
                dest=media/(key+'.pcm');dest.write_bytes(pcm)
                manifest[key]=dict(kind='audio',file='media/'+dest.name,rate=rate,channels=2,duration=frames/rate,original=name)
                src.unlink();wav.unlink()
        (out/(lang+'.json')).write_text(json.dumps(story,ensure_ascii=False),encoding='utf-8')
        reports[lang]={'chapters':len(story['chapters']),'events':len(story['events']),
                      'text_pages':sum(x['op']=='text' for x in story['events']),
                      'audio_cues':sum(x['op']=='audio' for x in story['events']),
                      'source_sha256':story['source_sha256']}
        license_dir=out/'notices'/lang;license_dir.mkdir(parents=True,exist_ok=True)
        for p in root.glob('*.txt'):shutil.copy2(p,license_dir/p.name)
    (out/'media.json').write_text(json.dumps(manifest,ensure_ascii=False),encoding='utf-8')
    reports['media']={'images':sum(x['kind']=='image' for x in manifest.values()),'audio':sum(x['kind']=='audio' for x in manifest.values()),'bytes':sum(p.stat().st_size for p in media.iterdir())}
    (out/'build-report.json').write_text(json.dumps(reports,indent=2),encoding='utf-8')
    # The scratch directory is exclusively created by this builder inside out.
    shutil.rmtree(scratch)
    print(json.dumps(reports,indent=2))

if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--en',required=True);ap.add_argument('--ja',required=True)
    ap.add_argument('--out',required=True);ap.add_argument('--ffmpeg',default='ffmpeg')
    a=ap.parse_args();build(a.en,a.ja,a.out,a.ffmpeg)
