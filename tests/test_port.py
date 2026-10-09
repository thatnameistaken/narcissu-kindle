"""Host tests. Requires Pillow and lupa (LuaJIT 2.1). No Kindle is simulated."""
import collections, hashlib, importlib.util, json, os, re, sys, tarfile, tempfile, unittest
from pathlib import Path
from lupa import luajit21
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('prepare',ROOT/'tools/prepare.py')
prepare=importlib.util.module_from_spec(spec);spec.loader.exec_module(prepare)
DATA=Path(os.environ.get('NARCISSU_TEST_DATA',ROOT/'narcissu.koplugin/data'))

def lua_table(lua,obj):
    if isinstance(obj,dict):return lua.table_from({k:lua_table(lua,v) for k,v in obj.items()})
    if isinstance(obj,list):return lua.table_from([lua_table(lua,x) for x in obj])
    return obj

class PortTests(unittest.TestCase):
    def setUp(self):
        self.lua=luajit21.LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute("package.loaded['libs/libkoreader-lfs']={mkdir=function() return true end}")
    def test_all_lua_compiles(self):
        compile=self.lua.eval('function(s,n) local f,e=loadstring(s,n); assert(f,e);return true end')
        for p in (ROOT/'narcissu.koplugin').glob('*.lua'):self.assertTrue(compile(p.read_text('utf-8'),p.name))
    def test_furigana_layout(self):
        exercise=self.lua.execute((ROOT/'tests/reading_fixture.lua').read_text('utf-8'))
        self.assertTrue(exercise((ROOT/'narcissu.koplugin').as_posix()))
    def test_player_resume_theme_header_and_controls(self):
        exercise=self.lua.execute((ROOT/'tests/player_fixture.lua').read_text('utf-8'))
        story=lua_table(self.lua,json.loads((DATA/'en.json').read_text('utf-8')))
        media=lua_table(self.lua,json.loads((DATA/'media.json').read_text('utf-8')))
        for header in [False,'filemanager','reader']:
            for width,height in [(600,800),(1072,1448),(1860,2480),(1404,3001)]:
                self.assertTrue(exercise((ROOT/'narcissu.koplugin').as_posix(),story,media,header,False,width,height))
    def test_audio_default_recovery_and_legacy_saves(self):
        exercise=self.lua.execute((ROOT/'tests/player_fixture.lua').read_text('utf-8'))
        story=lua_table(self.lua,json.loads((DATA/'en.json').read_text('utf-8')))
        media=lua_table(self.lua,json.loads((DATA/'media.json').read_text('utf-8')))
        for mode in ['disabled','recovery']:
            self.assertTrue(exercise((ROOT/'narcissu.koplugin').as_posix(),story,media,False,mode))
        japanese=lua_table(self.lua,json.loads((DATA/'ja.json').read_text('utf-8')))
        self.assertTrue(exercise((ROOT/'narcissu.koplugin').as_posix(),japanese,media,False,'slash'))
    def test_disabled_audio_does_not_load_native_libraries(self):
        audio=self.lua.execute((ROOT/'narcissu.koplugin/audio.lua').read_text('utf-8'))
        check=self.lua.eval('''function(Audio)
            local ffi=require('ffi');local saved=ffi.load;local calls=0
            ffi.load=function() calls=calls+1;error('must not load') end
            local ok,a=pcall(Audio.new,'.',{},nil,{disabled=true});ffi.load=saved
            assert(ok and a.disabled and not a.available and calls==0)
            assert(not a:play('music','test',true));a:tick(0.25);a:close();return true
        end''')
        self.assertTrue(check(audio))
    def test_furigana_preserves_original_text(self):
        ruby=json.loads((DATA/'ja-ruby.json').read_text('utf-8'))
        story=json.loads((DATA/'ja.json').read_text('utf-8'))
        self.assertEqual(ruby['source_sha256'],story['source_sha256'])
        for text,tokens in ruby['passages'].items():
            self.assertEqual(text,''.join(t['base'] for t in tokens))
        for ev in story['events']:
            if ev['op']=='text':self.assertIn(ev['text'],ruby['passages'])
    def test_audio_load_and_reload_without_kindle(self):
        for _ in range(2):
            audio=self.lua.execute((ROOT/'narcissu.koplugin/audio.lua').read_text('utf-8'))
            a=audio.new('.',self.lua.table(),None)
            self.assertFalse(bool(a.available));self.assertIn('unavailable',a.error)
            a.close(a)
    def check_system_audio(self,old):
        exercise=self.lua.execute((ROOT/'tests/system_audio_fixture.lua').read_text('utf-8'))
        self.assertTrue(exercise((ROOT/'narcissu.koplugin').as_posix(),old))
    def test_system_audio_gstreamer_010(self):self.check_system_audio(True)
    def test_system_audio_gstreamer_1(self):self.check_system_audio(False)
    def test_refresh_regions_and_clearing_intervals(self):
        exercise=self.lua.execute((ROOT/'tests/refresh_fixture.lua').read_text('utf-8'))
        source=(ROOT/'narcissu.koplugin/main.lua').read_text('utf-8')
        for w,h in [(600,800),(1072,1448),(1860,2480),(1404,3001)]:
            self.assertTrue(exercise(source,w,h,False))
    def test_text_pagination_uses_regional_refresh_policy(self):
        exercise=self.lua.execute((ROOT/'tests/refresh_fixture.lua').read_text('utf-8'))
        self.assertTrue(exercise((ROOT/'narcissu.koplugin/main.lua').read_text('utf-8'),600,800,True))
    def test_both_stories_run_to_end_and_restore_every_page(self):
        engine=self.lua.execute((ROOT/'narcissu.koplugin/engine.lua').read_text('utf-8'))
        step_check=self.lua.eval('''function(E,story)
            local e=E.new(story);local pages=0;local chapters=0;local voices=0
            while e.state.pc<=#story.events do
                local event=e:step()
                if event.op=='chapter' then chapters=chapters+1 end
                if event.op=='audio' and event.channel=='wave0' then voices=voices+1 end
                if event.op=='text' then
                    pages=pages+1
                    local saved=e:snapshot();local resumed=E.new(story);resumed:restore(saved)
                    assert(resumed.state.pc==e.state.pc and resumed.state.text==e.state.text)
                    local original_pc=e.state.pc;saved.pc=1;assert(e.state.pc==original_pc)
                    if e.state.pc<=#story.events then
                        local expected=story.events[e.state.pc];local actual=resumed:step()
                        assert(actual.op==expected.op and actual.asset==expected.asset and actual.text==expected.text)
                    end
                end
            end
            assert(e:step().op=='end')
            for i,c in ipairs(story.chapters) do e:chapter(i);assert(e:step().op=='chapter' and e.state.chapter==i) end
            local ok=pcall(function() e:restore({pc=-1,text='',audio={}}) end);assert(not ok)
            return pages,chapters,voices
        end''')
        for lang in ['en','ja']:
            story=json.loads((DATA/(lang+'.json')).read_text('utf-8'))
            pages,chapters,voices=step_check(engine,lua_table(self.lua,story))
            self.assertGreater(pages,2200);self.assertEqual(chapters,9);self.assertEqual(voices,439)
    def test_every_media_reference_and_pcm_duration(self):
        from PIL import Image
        media=json.loads((DATA/'media.json').read_text('utf-8'))
        for lang in ['en','ja']:
            story=json.loads((DATA/(lang+'.json')).read_text('utf-8'))
            self.assertEqual(sum(e['op']=='audio' for e in story['events']),576)
            for ev in story['events']:
                if 'asset' in ev:self.assertIn(ev['asset'],media)
        for key,m in media.items():
            p=DATA/m['file'];self.assertTrue(p.is_file(),str(p))
            if m['kind']=='audio':self.assertAlmostEqual(p.stat().st_size/(m['rate']*4),m['duration']+m.get('lead_in',0)+m.get('tail',0),places=6)
            else:
                with Image.open(p) as im:im.verify()
                with Image.open(DATA/m['display']) as im:im.verify()
    def test_audio_padding_preserves_every_payload_and_loop(self):
        media=json.loads((DATA/'media.json').read_text(encoding='utf-8'))
        loops={e['asset'] for lang in ['en','ja'] for e in json.loads((DATA/(lang+'.json')).read_text(encoding='utf-8'))['events'] if e['op']=='audio' and e['loop']}
        padded=0;voices=0
        for key,m in media.items():
            if m['kind']!='audio':continue
            raw=(DATA/m['file']).read_bytes()
            if key in loops:self.assertNotIn('lead_in',m);continue
            padded+=1
            head=round(m['lead_in']*m['rate'])*4;tail=round(m['tail']*m['rate'])*4
            self.assertEqual(raw[:head],bytes(head));self.assertEqual(raw[-tail:],bytes(tail))
            payload=raw[head:-tail]
            self.assertEqual(hashlib.sha256(payload).hexdigest(),m['payload_sha256'])
            self.assertEqual(len(payload),m['payload_bytes'])
            self.assertNotEqual(payload,bytes(len(payload)),m['original'])
            if m['original'].startswith('w/'):
                voices+=1;self.assertEqual(m['voice_gain_db'],1.5)
                self.assertNotEqual(m['payload_sha256'],m['original_payload_sha256'])
                from array import array
                samples=array('h');samples.frombytes(payload)
                self.assertLess(max(samples),32767);self.assertGreater(min(samples),-32768)
        self.assertEqual(padded,399)
        self.assertEqual(voices,361)
    def test_storage_backup_recovers_corrupt_current(self):
        # Real Lua file IO and rename, with Python JSON only replacing rapidjson.
        self.lua.globals().pyencode=lambda x:json.dumps(dict(x))
        self.lua.globals().pydecode=lambda s:lua_table(self.lua,json.loads(s))
        self.lua.execute("package.preload.rapidjson=function() return {encode=pyencode,decode=pydecode} end")
        storage=self.lua.execute((ROOT/'narcissu.koplugin/storage.lua').read_text('utf-8'))
        with tempfile.TemporaryDirectory() as d:
            path=str(Path(d)/'save.json').replace('\\','/')
            self.assertTrue(storage.save(path,self.lua.table_from({'pc':100})))
            self.assertTrue(storage.save(path,self.lua.table_from({'pc':200})))
            self.assertEqual(storage.load(path).pc,200)
            Path(path).write_text('{broken')
            self.assertEqual(storage.load(path).pc,100)
    def test_compiler_rejects_unknown_command(self):
        fake='*image_voice\nunsupported_command\n*text_lb'
        with self.assertRaisesRegex(ValueError,'unsupported story command'):prepare.compile_story(fake,'en')
    def test_text_matches_original_releases(self):
        releases=ROOT/'original-releases'
        if not releases.exists():self.skipTest('Original archives not installed')
        for lang in ['en','ja']:
            story=json.loads((DATA/(lang+'.json')).read_text('utf-8'))
            if lang=='ja':
                self.assertEqual(story['events'][3854],{'op':'noop'})
                self.assertEqual(story['chapters'][8]['index'],3937)
            with tarfile.open(releases/(lang+'.tar.bz2')) as tar:
                member=next(m for m in tar if m.name.endswith('/nscript.dat'))
                script=prepare.decode_script(tar.extractfile(member).read())
            lines=script.splitlines();lines=lines[lines.index('*image_voice'):lines.index('*text_lb')]
            fragments=[]
            for line in lines:
                line=line.strip()
                if line and (line.startswith('`') or ord(line[0])>127 or line.startswith('"')):
                    if line.startswith('`'):line=line[1:]
                    if lang=='ja':line=line.replace('@/','@')
                    fragments.append(line.replace('\\','').replace('@',''))
            story=json.loads((DATA/(lang+'.json')).read_text('utf-8'))
            original=re.sub(r'\s+','',''.join(fragments))
            actual=re.sub(r'\s+','',''.join(e['text'] for e in story['events'] if e['op']=='text'))
            self.assertEqual(actual,original)

if __name__=='__main__':unittest.main(verbosity=2)
