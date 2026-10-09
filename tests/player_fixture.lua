return function(root,story,media,header,mode,width,height)
    local Widget={}
    function Widget:extend(o) return setmetatable(o,{__index=self}) end
    function Widget:new(o) o=setmetatable(o or {},{__index=self});if o.init then o:init() end;return o end
    function Widget:getSize() return {w=self.width or 100,h=self.height or 20} end
    function Widget:free() end
    function Widget:paintTo() end
    local Text=Widget:extend{}
    function Text:init() self.virtual_line_num=1;self.lines_per_page=5;self.vertical_string_list={{text=self.text}} end
    function Text:scrollDown() self.virtual_line_num=self.virtual_line_num+5 end
    function Text:scrollUp() self.virtual_line_num=math.max(1,self.virtual_line_num-5) end
    function Text:_getLineText(line) return line.text end
    function Text:paintTo(_,x,y) self.painted={x=x,y=y} end
    width=width or 600;height=height or 800
    local screen={night_mode=false,getWidth=function() return width end,getHeight=function() return height end,scaleBySize=function(_,n) return n end}
    local ui={_window_stack={},scheduled={},dirty={}}
    function ui:show(w) self._window_stack[#self._window_stack+1]={widget=w};if w.onShow then w:onShow() end end
    function ui:close(w)
        for i=#self._window_stack,1,-1 do if self._window_stack[i].widget==w then table.remove(self._window_stack,i) end end
        if w.onCloseWidget then w:onCloseWidget() end
    end
    function ui:setDirty(w,mode,r) self.dirty[#self.dirty+1]={widget=w,mode=mode,region=r} end
    function ui:scheduleIn(t,fn) self.scheduled[fn]=t end
    function ui:unschedule(fn) self.scheduled[fn]=nil end
    function ui:nextTick(fn) self:scheduleIn(0,fn) end
    package.loaded['ui/uimanager']=ui
    package.loaded.device={screen=screen,hasFrontlight=function() return true end}
    package.loaded['ffi/blitbuffer']={COLOR_BLACK=0,COLOR_WHITE=255}
    package.loaded['ui/font']={getFace=function() return {} end}
    package.loaded.datastorage={getSettingsDir=function() return '/fake/settings' end}
    package.loaded['libs/libkoreader-lfs']={mkdir=function() end}
    for _,name in ipairs({'container/widgetcontainer','container/inputcontainer','widget','buttondialog','infomessage','confirmbox','frontlightwidget','imagewidget'}) do
        package.loaded['ui/widget/'..name]=Widget
    end
    package.loaded['ui/widget/textwidget']=Text;package.loaded['ui/widget/textboxwidget']=Text
    package.loaded['ui/geometry']=Widget;package.loaded['ui/gesturerange']=Widget
    local Engine=dofile(root..'/engine.lua')
    local e=Engine.new(story)
    repeat e:step() until e.state.pc>50 and e.state.text~=''
    local saved={version=1,language=story.language,hash=story.source_sha256,state=e:snapshot(),positions={},backlog={{text='Earlier',language='en',chapter=1,pc=2}}}
    if mode=='slash' then saved.state.pc=3856;saved.state.chapter=8;saved.state.text='/' end
    local original_pc=saved.state.pc
    local files={['/fake/settings/narcissu/auto.json']=saved}
    files['/fake/settings/narcissu/preferences.json']={font=24,voice=true,audio_revision='audio-recovery-1',audio_enabled=mode~='disabled'}
    if mode=='recovery' then files['/fake/settings/narcissu/audio-session.json']={active=true} end
    local storage={load=function(p) return files[p] end,save=function(p,s) files[p]=s;return true end,
        read=function(p) if p:match('/media.json$') then return media elseif p:match('/[ej][na].json$') then return story else return files[p] end end}
    local Audio={}
    function Audio.new(_,_,_,options)
        local a={available=not options.disabled,disabled=options.disabled or nil,voice=true,channels={},events={}}
        function a:setMuted(v) self.muted=v;if v then self:close() end end
        function a:close() self.channels={} end
        function a:play(channel,asset,loop) if self.available and not self.muted then self.channels[channel]={asset=asset,loop=loop} end end
        function a:stop(channel) self.channels[channel]=nil end
        function a:tick() end
        function a:positions() return {} end
        function a:pause(v) self.paused=v end
        function a:voiceBusy() return false end
        function a:status() return 'Test audio status' end
        return a
    end
    local env=setmetatable({dofile=function(p)
        if p:match('/storage.lua$') then return storage elseif p:match('/audio.lua$') then return Audio else return dofile(p) end
    end,os=setmetatable({remove=function(p) files[p]=nil;return true end},{__index=os})},{__index=_G})
    local f=assert(loadfile(root..'/main.lua'));setfenv(f,env);local Plugin=f()
    local host={menu={registerToMainMenu=function() end}}
    if header=='filemanager' then
        host.title_bar={dimen={y=0},getHeight=function() return 60 end,title_group={{},{_zen_status_item_values={time='12:00'}}}}
        host._updateStatusBar=function() host.updated=true end
    elseif header=='reader' then host.view={_zen_header_dimen={y=0,h=60}} end
    local plugin=Plugin:new{ui=host};plugin:open()
    assert(plugin.player,ui._window_stack[#ui._window_stack].widget.text)
    local p=plugin.player
    if mode=='recovery' then
        assert(p.audio.disabled and not p.audio.available)
        assert((p.audio_recovered==true)==(mode=='recovery'))
        assert(not files['/fake/settings/narcissu/preferences.json'].audio_enabled)
        ui:close(ui._window_stack[#ui._window_stack].widget)
        p:mute();assert(p.audio.available and files['/fake/settings/narcissu/audio-session.json'].active)
        p:enableAudio(false);assert(p.audio.disabled and not files['/fake/settings/narcissu/audio-session.json'])
        p:replayVoice() -- safe even if this early passage has no voice
        p:enableAudio(true)
    else
        assert(p.audio.available and files['/fake/settings/narcissu/preferences.json'].audio_enabled,'Default on must migrate old disabled preferences too')
    end
    assert(p.engine.state.pc==original_pc,'Opening must restore the original autosave before writing a new one')
    if mode=='slash' then assert(p.engine.state.text==story.events[3854].text and p.engine.state.text~='/') end
    assert(files['/fake/settings/narcissu/auto.json'].state.pc==original_pc)
    assert(p.backlog==nil and p.showLog==nil and files['/fake/settings/narcissu/auto.json'].backlog==nil)
    assert(p.top==(header and 60 or 0));assert(p.upper.h+p.lower.h+p.top==height)
    assert(p.covers_fullscreen==not header)
    if header then
        assert(not p:onTap(nil,{pos={x=50,y=20}}))
        p:_zen_status_refresh();assert(ui.dirty[#ui.dirty].widget==host and ui.dirty[#ui.dirty].region.h==60)
    end
    assert(p:colors()==0);p.prefs.dark=true;assert(p:colors()==255)
    screen.night_mode=true;assert(p:colors()==0);p.prefs.dark=false;assert(p:colors()==255)
    p:onMenu();local menu=ui._window_stack[#ui._window_stack].widget
    assert(#menu.buttons==8)
    local mute,volume,replay=false,false,false
    for _,row in ipairs(menu.buttons) do for _,b in ipairs(row) do
        assert(not b.text:find('Auto') and not b.text:find('log') and b.text~='Audio' and not b.text:find('check'))
        if b.text=='Mute' then mute=true elseif b.text=='Volume' then volume=true elseif b.text=='Replay voice line' then replay=true end
    end end
    assert(mute and not volume and replay);ui:close(menu)
    assert(p.volumeControls==nil)
    -- Paint and tap share exactly the same boundaries, at every screen size.
    p:paintTo({paintRect=function() end},0,0)
    local previous,menu_action,next_action=p.onPrevious,p.onMenu,p.onNext
    local hit
    p.onPrevious=function() hit=1 end;p.onMenu=function() hit=2 end;p.onNext=function() hit=3 end
    for i,b in ipairs(p.footer) do
        local size=b.label:getSize()
        assert(math.abs(b.label.painted.x+size.w/2-(b.x+b.w/2))<=0.5)
        for _,x in ipairs({b.x,b.x+math.floor(b.w/2),b.x+b.w-1}) do
            p:onTap(nil,{pos={x=x,y=height-1}});assert(hit==i)
        end
    end
    p.onPrevious=previous;p.onMenu=menu_action;p.onNext=next_action
    local snapshot=p.engine:snapshot()
    for n,event in ipairs(story.events) do
        if event.op=='audio' and media[event.asset].original:match('^w/') then
            p.engine.state.pc=n+1
            local music=p.audio.channels.music
            p:replayVoice();assert(p.audio.channels[event.channel].asset==event.asset)
            assert(p.audio.channels.music==music,'Replay must not restart music');break
        end
    end
    p.engine:restore(snapshot)
    p:mute();assert(p.audio.muted);p:mute();assert(not p.audio.muted)
    p:onSuspend();assert(p.audio.paused)
    assert(p.auto==nil and p.armAuto==nil)
    p:onResume();assert(not p.audio.paused)
    -- Host shutdown must close the player and stop its timers and audio too.
    plugin:onExit();assert(plugin.player==nil and p.closed and next(p.audio.channels)==nil)
    assert(not files['/fake/settings/narcissu/audio-session.json'])
    return true
end
