-- Execute the real process backend with fake OS/filesystem boundaries.
return function(root,old)
    local files={};local commands={};local kills={};local focuses=0
    files[old and '/usr/bin/gst-launch-0.10' or '/usr/bin/gst-launch-1.0']=''
    files['/usr/bin/lipc-set-prop']=''
    local media={
        music={kind='audio',file='music.pcm',original='bgm/test.mp3',rate=44100,channels=2,duration=10},
        voice={kind='audio',file="voice 'test'.pcm",original='w/voice.wav',rate=44100,channels=2,duration=2,lead_in=1,tail=1.5},
        effect={kind='audio',file='effect.pcm',original='se/effect.wav',rate=22050,channels=2,duration=0.1,lead_in=1,tail=1.5},
    }
    for _,m in pairs(media) do files['/mnt/us/game/'..m.file]='PCM' end
    local fakeio={open=function(path,mode)
        local value=files[path]
        if path:match('%.pid$') and value==nil then value='500' end
        if path=='/proc/500/cmdline' then
            value='audio-runner.sh';for n=1,50 do value=value..' /tmp/narcissu-audio-123/'..n end
        end
        if mode:find('w') then files[path]='';value='' end
        if value==nil then return end
        return {seek=function(_,whence) return whence=='end' and #value or 0 end,
            read=function() return value end,close=function() end,
            write=function(_,text) files[path]=(files[path] or '')..text;return true end}
    end}
    local fakeffi={cdef=function() end,C={getpid=function() return 123 end,
        kill=function(pid,signal) kills[#kills+1]={pid,signal};return 0 end}}
    local env=setmetatable({io=fakeio,os={date=function() return '12:00:00' end,
        execute=function(cmd)
            assert(not cmd:find('speakerVolume',1,true),'The port must not write system volume')
            if cmd:find('setFocus Music',1,true) then focuses=focuses+1
            else commands[#commands+1]=cmd end
            return 0
        end},require=function(name)
            if name=='ffi' then return fakeffi end
            if name=='libs/libkoreader-lfs' then return {mkdir=function() return true end} end
            return require(name)
        end},{__index=_G})
    local loader=assert(loadfile(root..'/audio.lua'));setfenv(loader,env);local Audio=loader()
    local a=Audio.new('/mnt/us/game',media)
    assert(a.available and a.old==old and focuses==1 and not a.software_volume)
    assert(a.getVolume==nil and a.setVolume==nil)
    assert(a:play('music','music',true));assert(a:play('wave0','voice',false));assert(a:play('wave1','effect',false))
    assert(a.channels.music and a.channels.wave0 and a.channels.wave1)
    assert(#commands==3 and focuses==1,'Do not reset headphone gain for each clip')
    for _,command in ipairs(commands) do
        assert(command:find('LD_LIBRARY_PATH= LD_PRELOAD= /bin/sh ',1,true))
        assert(command:find('audio-runner.sh',1,true));assert(not command:find('volume',1,true))
    end
    assert(commands[2]:find("'voice",1,true)==nil) -- path is a single quoted whole argument
    assert(commands[2]:find("voice '\\''test'\\''.pcm",1,true),'Shell apostrophes must be escaped')
    local voice=a.channels.wave0;local effect=a.channels.wave1;local music=a.channels.music
    for _=1,100 do a:tick(0.25) end
    assert(a.channels.wave0 and a.channels.wave1 and a.channels.music,'Elapsed time cannot terminate streams')
    files[voice.prefix..'.done']='0';a:tick(0.25);assert(not a.channels.wave0 and a.channels.wave1)
    files[effect.prefix..'.done']='4';files[effect.prefix..'.log']='sink rejected caps'
    a:tick(0.25);assert(not a.channels.wave1 and a.error:find('se/effect.wav',1,true) and a.error:find('sink rejected caps',1,true))
    files[music.prefix..'.loops']='3';a:tick(0.25);assert(a.channels.music and music.loops==3)
    a:pause(true);assert(a.paused and not music.prefix)
    a:pause(false);assert(music.prefix and focuses==2)
    local oldprefix=music.prefix;a:stop('music');assert(files[oldprefix..'.cancel']=='stop')
    assert(kills[#kills][2]==15)
    a:setMuted(true);assert(not a:play('wave0','voice',false))
    a:setMuted(false);a.voice=false;assert(not a:play('wave0','voice',false));assert(a:play('wave1','effect',false))
    a:close();assert(next(a.channels)==nil)
    return true
end
