"""Run the actual shell supervisor with a fake gst-launch, never a Kindle."""
import os,shutil,subprocess,tempfile,time,unittest
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
BASH=shutil.which('bash')
if not BASH and Path('C:/Program Files/Git/bin/bash.exe').is_file():BASH='C:/Program Files/Git/bin/bash.exe'

@unittest.skipUnless(BASH,'A POSIX shell is required')
class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.work=Path(self.temp.name)
        self.prefix=self.work/'stream';self.trace=self.work/'trace'
        self.fake=self.work/'gst';self.clip=self.work/'clip "speaker\'s".pcm'
        self.fake.write_text('''#!/bin/sh
printf 'GST_PLUGIN_PATH=%s\\n' "${GST_PLUGIN_PATH-unset}" >> "$FAKE_GST_TRACE"
printf '%s\\n' "$@" >> "$FAKE_GST_TRACE"
if [ "${FAKE_GST_EXEC_SLEEP-0}" = 1 ]; then exec sleep "$FAKE_GST_SLEEP"; fi
sleep "${FAKE_GST_SLEEP-0}"
printf 'fake gst diagnostic\\n'
exit "${FAKE_GST_CODE-0}"
''',encoding='utf-8',newline='\n')
        self.fake.chmod(0o755)
    def tearDown(self):self.temp.cleanup()
    def launch(self,old=True,loop=False,minimum=0,sleep='0',code='0',parent_pid=None):
        env=os.environ.copy();env.update(FAKE_GST_TRACE=self.trace.as_posix(),FAKE_GST_SLEEP=sleep,FAKE_GST_CODE=code,GST_PLUGIN_PATH='should-be-cleared')
        # exec keeps $$ valid for the supervisor's parent check in these tests.
        command='exec /bin/sh "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$$" "$9"'
        if parent_pid:
            command=command.replace('"$$"',str(int(parent_pid)))
            env['FAKE_GST_EXEC_SLEEP']='1'
        return subprocess.Popen([BASH,'-c',command,'runner-test',(ROOT/'narcissu.koplugin/audio-runner.sh').as_posix(),self.fake.as_posix(),str(int(old)),self.clip.as_posix(),'44100','2',str(int(loop)),self.prefix.as_posix(),str(minimum)],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    def wait_file(self,suffix,predicate=lambda s:True):
        path=Path(str(self.prefix)+suffix);deadline=time.monotonic()+10
        while time.monotonic()<deadline:
            if path.exists():
                value=path.read_text().strip()
                if value and predicate(value):return value
            time.sleep(0.05)
        self.fail('Timed out waiting for '+suffix)
    def test_old_and_new_caps_and_safe_location_quoting(self):
        for old in (True,False):
            p=self.launch(old=old);out,err=p.communicate(timeout=15)
            self.assertEqual(p.returncode,0,(out,err))
            self.assertEqual(self.wait_file('.done'),'0')
            trace=self.trace.read_text()
            self.assertIn('audio/x-raw-int' if old else 'audio/x-raw,format=S16LE',trace)
            self.assertIn('stream-type=Music\nsync=true',trace)
            self.assertIn('GST_PLUGIN_PATH=unset',trace)
            escaped=self.clip.as_posix().replace('\\','\\\\').replace('"','\\"')
            self.assertIn('location="'+escaped+'"\n',trace)
    def test_pipeline_error_preserves_status_and_log(self):
        p=self.launch(code='4');p.communicate(timeout=15)
        self.assertEqual(p.returncode,4);self.assertEqual(self.wait_file('.done'),'4')
        self.assertIn('fake gst diagnostic',Path(str(self.prefix)+'.log').read_text())
    def test_premature_success_is_a_failure(self):
        p=self.launch(minimum=5);p.communicate(timeout=15)
        self.assertEqual(p.returncode,70);self.assertEqual(self.wait_file('.done'),'70')
    def test_music_loop_and_signal_cleanup(self):
        p=self.launch(loop=True,sleep='0.1')
        try:
            self.wait_file('.loops',lambda s:int(s)>=2)
            pid=self.wait_file('.pid')
            subprocess.run([BASH,'-c','kill -TERM "$1"','kill-test',pid],check=True,timeout=5)
            p.communicate(timeout=10);self.assertEqual(self.wait_file('.done'),'143')
        finally:
            if p.poll() is None:p.kill();p.communicate(timeout=5)
    def test_cancel_before_pid_capture_starts_no_pipeline(self):
        Path(str(self.prefix)+'.cancel').write_text('stop')
        p=self.launch();p.communicate(timeout=15)
        self.assertEqual(self.wait_file('.done'),'143');self.assertFalse(self.trace.exists())
    def test_owner_exit_stops_background_audio(self):
        owner=subprocess.Popen([BASH,'-c','printf "%s\\n" "$$"; sleep 1'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        parent=owner.stdout.readline().decode().strip()
        p=self.launch(sleep='20',parent_pid=parent)
        try:
            owner.communicate(timeout=5)
            p.communicate(timeout=10)
            self.assertEqual(self.wait_file('.done'),'143')
        finally:
            if owner.poll() is None:owner.kill();owner.communicate(timeout=5)
            if p.poll() is None:p.kill();p.communicate(timeout=5)

if __name__=='__main__':unittest.main(verbosity=2)
