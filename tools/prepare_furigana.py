"""Create optional, offline furigana; no tokenizer is required on the Kindle.

Requires fugashi and unidic-lite. Readings are machine-generated study aids,
not editorially verified. The base script and save hashes are unchanged.
"""
import argparse,json,re
from pathlib import Path

def hira(s):
    return ''.join(chr(ord(c)-0x60) if '\u30a1'<=c<='\u30f6' else c for c in s)

def annotate(tagger,text):
    tokens=[];cursor=0
    for word in tagger(text):
        base=word.surface;start=text.index(base,cursor)
        if start>cursor:tokens.append({'base':text[cursor:start]})
        cursor=start+len(base)
        reading=getattr(word.feature,'kana',None) or getattr(word.feature,'pron',None)
        if re.search(r'[\u3400-\u9fff々]',base) and reading and reading!='*':
            reading=hira(reading)
            # Keep matching okurigana outside the ruby, including inflections.
            suffix=''
            while base and reading and base[-1]==reading[-1] and '\u3041'<=base[-1]<='\u3096':
                suffix=base[-1]+suffix;base=base[:-1];reading=reading[:-1]
            if base:tokens.append({'base':base,'reading':reading})
            if suffix:tokens.append({'base':suffix})
        else:tokens.append({'base':base})
    if cursor<len(text):tokens.append({'base':text[cursor:]})
    assert ''.join(t['base'] for t in tokens)==text
    return tokens

def build(data,out):
    import fugashi
    tagger=fugashi.Tagger()
    story=json.loads(Path(data).read_text('utf-8'));texts=set();visible=''
    for e in story['events']:
        if e['op']=='chapter':visible=''
        if e['op']=='text':
            texts.add(e['text']);visible=e['text'] if e['clear'] else visible+'\n'+e['text'];texts.add(visible)
    passages={t:annotate(tagger,t) for t in sorted(texts)}
    result={'format':1,'source_sha256':story['source_sha256'],
            'notice':'Machine-generated with fugashi/UniDic-lite; readings can be wrong, especially names and ambiguous words.',
            'passages':passages}
    Path(out).write_text(json.dumps(result,ensure_ascii=False,separators=(',',':')),encoding='utf-8')
    print(len(passages),'annotated passages;',sum('reading' in t for ts in passages.values() for t in ts),'ruby tokens')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--data',required=True);p.add_argument('--out',required=True)
    a=p.parse_args();build(a.data,a.out)
