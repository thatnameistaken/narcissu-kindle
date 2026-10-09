local WidgetContainer=require('ui/widget/container/widgetcontainer')
local InputContainer=require('ui/widget/container/inputcontainer')
local UIManager=require('ui/uimanager')
local Device=require('device')
local Screen=Device.screen
local Geom=require('ui/geometry')
local GestureRange=require('ui/gesturerange')
local Font=require('ui/font')
local TextBoxWidget=require('ui/widget/textboxwidget')
local TextWidget=require('ui/widget/textwidget')
local ImageWidget=require('ui/widget/imagewidget')
local Blitbuffer=require('ffi/blitbuffer')
local ButtonDialog=require('ui/widget/buttondialog')
local InfoMessage=require('ui/widget/infomessage')
local ConfirmBox=require('ui/widget/confirmbox')
local DataStorage=require('datastorage')
local lfs=require('libs/libkoreader-lfs')
local ROOT=debug.getinfo(1,'S').source:sub(2):match('^(.*)/[^/]+$')
local Engine=dofile(ROOT..'/engine.lua')
local Storage=dofile(ROOT..'/storage.lua')
local Audio=dofile(ROOT..'/audio.lua')
local Ruby=dofile(ROOT..'/rubywidget.lua')
local DATA=ROOT..'/data'
local SAVE=DataStorage:getSettingsDir()..'/narcissu'
local Player=InputContainer:extend{covers_fullscreen=true,name='NarcissuPlayer'}
local function info(message) UIManager:show(InfoMessage:new{text=message}) end

function Player:init()
    lfs.mkdir(SAVE)
    self.prefs=Storage.load(SAVE..'/preferences.json') or {font=24}
    self.prefs.audio_revision='audio-on-2';self.prefs.audio_enabled=true
    self.prefs.voice=true;self.prefs.volume=nil
    local previous_audio=Storage.read(SAVE..'/audio-session.json')
    if previous_audio and previous_audio.active then self.prefs.audio_enabled=false;self.audio_recovered=true end
    self.prefs.auto_speed=nil
    self:preferences()
    self.history={};self.text_refreshes=0;self.image_refreshes=0;self.closed=false;self.generation=0
    self.dimen=Geom:new{x=0,y=0,w=Screen:getWidth(),h=Screen:getHeight()}
    self.top=0;self.host=self.owner and self.owner.ui
    -- Leave the existing host widget visible and interactive. Never rebuild it.
    local tb=self.host and self.host.title_bar
    local row=tb and tb.title_group and tb.title_group[2]
    local rect=self.host and self.host.view and self.host.view._zen_header_dimen
    if row and row._zen_status_item_values and tb.dimen then
        self.top=tb.dimen.y+tb:getHeight()
    elseif rect then self.top=rect.y+rect.h end
    if self.top<0 or self.top>self.dimen.h/3 then self.top=0 end
    self.covers_fullscreen=self.top==0
    self.header=Geom:new{x=0,y=0,w=self.dimen.w,h=self.top}
    self.split=self.top+math.floor((self.dimen.h-self.top)/2)
    self.margin=Screen:scaleBySize(20);self.bar=Screen:scaleBySize(54)
    self.lower=Geom:new{x=0,y=self.split,w=self.dimen.w,h=self.dimen.h-self.split}
    self.upper=Geom:new{x=0,y=self.top,w=self.dimen.w,h=self.split-self.top}
    self.ges_events={
        Tap={GestureRange:new{ges='tap',range=self.dimen}},
        Swipe={GestureRange:new{ges='swipe',range=self.dimen}},
        Menu={GestureRange:new{ges='hold',range=self.dimen}},
    }
    self.key_events={Next={{'Right'},{'PageForward'}},Previous={{'Left'},{'PageBack'}},Menu={{'Menu'},{'Back'}},Quit={{'Home'}}}
    self.media=assert(Storage.read(DATA..'/media.json'),'Missing media index')
    self:createAudio()
    self.tick=function()
        if self.closed then return end
        self.audio:tick(0.25)
        local minute=os.date('%H:%M')
        if minute~=self.last_minute then self.last_minute=minute;self:_zen_status_refresh() end
        UIManager:scheduleIn(0.25,self.tick)
    end
    self:language(self.language_code or 'en',self.initial_save)
    self.initial_save=nil
    UIManager:scheduleIn(0.25,self.tick)
end
function Player:createAudio()
    if self.prefs.audio_enabled then
        local ok=Storage.save(SAVE..'/audio-session.json',{active=true})
        if not ok then self.prefs.audio_enabled=false;self:preferences();info('Audio remains off because its recovery record could not be saved.') end
    end
    self.audio=Audio.new(DATA,self.media,function(err)
        if not self.audio_warned then
            self.audio_warned=true
            UIManager:nextTick(function() if not self.closed then info('Audio unavailable: '..err..'\nYou can continue reading silently.') end end)
        end
    end,{disabled=not self.prefs.audio_enabled})
    self.audio.log_path=SAVE..'/audio-status.txt'
    self.audio.voice=true
    self.audio:setMuted(self.prefs.muted==true)
end
function Player:enableAudio(value)
    self.prefs.audio_enabled=value;self:preferences()
    self.audio:close()
    if not value then os.remove(SAVE..'/audio-session.json') end
    self.audio_warned=false;self:createAudio()
    if value then self:restoreAudio() end
end
function Player:language(lang,saved)
    assert(lang=='en' or lang=='ja','Unknown language')
    local story=Storage.read(DATA..'/'..lang..'.json')
    assert(story and story.format==1,'Story data missing or incompatible')
    self:cancel();self.audio:close();self.history={};self.language_code=lang
    self.engine=Engine.new(story);self.boundary=false;self.finished=false
    if saved then
        assert(saved.version==1,'Unsupported save version')
        assert(saved.hash==story.source_sha256,'This save belongs to a different game edition')
        self.engine:restore(saved.state);self.boundary=true;self.finished=saved.finished
        if lang=='ja' and self.engine.state.text=='/' then
            for n=self.engine.state.pc-1,1,-1 do
                local ev=story.events[n]
                if ev.op=='text' then self.engine.state.text=ev.text;self.engine.state.line=1;break end
            end
        end
        self:restoreAudio(saved.positions);self:render(true);self:save('auto')
    else self:render(true);self:advance() end
end
function Player:cancel()
    self.generation=self.generation+1
    if self.pending then UIManager:unschedule(self.pending);self.pending=nil end
end
function Player:later(seconds)
    local gen=self.generation
    self.pending=function()
        self.pending=nil
        if not self.closed and gen==self.generation then self:advance() end
    end
    UIManager:scheduleIn(seconds,self.pending)
end
function Player:restoreAudio(positions)
    self.audio:close();self.audio.paused=false
    for channel,v in pairs(self.engine.state.audio) do
        self.audio:play(channel,v.asset,v.loop,channel~='wave0' and positions and positions[channel] or nil)
    end
end
function Player:save(slot)
    if not self.boundary then return true end
    if self.textbox then self.engine.state.line=self.textbox.virtual_line_num end
    local save={version=1,language=self.language_code,hash=self.engine.story.source_sha256,
        state=self.engine:snapshot(),positions=self.audio:positions(),finished=self.finished,time=os.date('%Y-%m-%d %H:%M')}
    local ok,err=Storage.save(SAVE..'/'..slot..'.json',save)
    if not ok and not self.save_warned then self.save_warned=true;info('Could not save progress: '..tostring(err)) end
    return ok
end
function Player:load(slot)
    local save=Storage.load(SAVE..'/'..slot..'.json')
    if not save then info('This save slot is empty or unreadable.');return end
    local ok,err=pcall(function() self:language(save.language,save) end)
    if not ok then info('Could not load save: '..tostring(err)) end
end
function Player:advance()
    if self.closed or self.suspended then return end
    self:cancel();self.boundary=false
    for _=1,1000 do
        local ev=self.engine:step()
        if ev.op=='audio' then self.audio:play(ev.channel,ev.asset,ev.loop)
        elseif ev.op=='fade' then self.fade=ev.ms
        elseif ev.op=='stop' then self.audio:stop(ev.channel,ev.channel=='music' and self.fade or nil)
        elseif ev.op=='chapter' then self.fade=0;self.finished=false
        elseif ev.op=='image' then self:render(true);self:later(0.35);return
        elseif ev.op=='wait' then self:later(ev.ms/1000);return
        elseif ev.op=='text' or ev.op=='click' or ev.op=='chapter_end' or ev.op=='end' then
            self.boundary=true
            if ev.op=='chapter_end' then self.engine.state.text=self.language_code=='ja' and '章の終わり。タップして次の章へ。' or 'End of chapter. Tap to continue.' end
            if ev.op=='end' then self.finished=true;self.engine.state.text=self.language_code=='ja' and 'おわり\n\nメニューから章を選択できます。' or 'The End\n\nOpen the menu to revisit a chapter.' end
            self:render(false);self:save('auto')
            self.history[#self.history+1]={state=self.engine:snapshot(),positions=self.audio:positions(),finished=self.finished}
            if #self.history>200 then table.remove(self.history,1) end
            return
        end
    end
    info('Story execution stopped: too many commands without a page boundary.')
end
function Player:dark()
    if self.prefs.dark==nil then return Screen.night_mode==true end
    return self.prefs.dark
end
function Player:colors()
    local dark=self:dark()~=(Screen.night_mode==true)
    return dark and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
        dark and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
end
function Player:makeText(text,lang,width,height)
    local fg,bg=self:colors()
    if lang=='ja' and self.prefs.furigana then
        if self.ruby_data==nil then self.ruby_data=Storage.read(DATA..'/ja-ruby.json') or false end
        local story=lang==self.language_code and self.engine.story or Storage.read(DATA..'/ja.json')
        local ruby=self.ruby_data
        if ruby and ruby.source_sha256==story.source_sha256 and ruby.passages[text] then
            return Ruby:new{text=text,tokens=ruby.passages[text],font_size=self.prefs.font,width=width,height=height,fgcolor=fg}
        end
    end
    return TextBoxWidget:new{text=text,face=Font:getFace('cfont',self.prefs.font),width=width,height=height,
        height_adjust=true,lang=lang,alignment='left',use_xtext=true,fgcolor=fg,bgcolor=bg}
end
function Player:_zen_status_refresh()
    if self.top==0 or not self.host then return end
    if self.host._updateStatusBar then self.host:_updateStatusBar(true,true) end
    UIManager:setDirty(self.host,'ui',self.header)
end
function Player:backlight()
        if Device:hasFrontlight() then UIManager:show(require('ui/widget/frontlightwidget'):new{})
    else info('Backlight controls are unavailable on this device.') end
end
function Player:mute()
    if self.audio.disabled then self.prefs.muted=false;self:enableAudio(true);return end
    self.prefs.muted=not self.audio.muted;self.audio:setMuted(self.prefs.muted)
    if not self.prefs.muted then self:restoreAudio() end
    self:preferences()
end
function Player:replayVoice()
    local voice
    -- Find the most recent voice in this chapter, including after save/load or Back.
    for n=self.engine.state.pc-1,1,-1 do
        local ev=self.engine.story.events[n]
        if ev.op=='chapter' then break end
        if ev.op=='audio' and self.media[ev.asset].original:match('^w/') then voice=ev;break end
    end
    if not voice then info('No voice line to replay in this chapter yet.');return end
    if self.audio.muted then info('Unmute to replay the voice line.');return end
    if self.audio.disabled then self:enableAudio(true) end
    self.audio:play(voice.channel,voice.asset,false)
end
function Player:refreshRegion(image)
    local key=image and 'image_refreshes' or 'text_refreshes'
    self[key]=(self[key] or 0)+1
    local interval=image and 6 or 8
    -- KOReader's ui mode is a non-flashing regional refresh appropriate for
    -- mixed grayscale/colour content. Avoid the global reader refresh counter.
    UIManager:setDirty(self,self[key]%interval==0 and 'flashui' or 'ui',image and self.upper or self.lower,image or false)
end
function Player:render(image_changed,full_refresh)
    local state=self.engine.state
    local first=not self.display_ready
    local update_image=first or state.image~=self.display_image
    local text_key=table.concat({state.text or '',tostring(state.line or 1),tostring(state.chapter),self.language_code,tostring(self.prefs.font),tostring(self:dark()),tostring(Screen.night_mode),tostring(self.prefs.furigana)},'\0')
    local update_text=first or text_key~=self.display_text
    if not update_image and not update_text and not full_refresh then return end
    if update_image then
        if self.picture then self.picture:free();self.picture=nil end
        local m=state.image and self.media[state.image]
        if m then self.picture=ImageWidget:new{file=DATA..'/'..(m.display or m.file),width=self.dimen.w,height=self.upper.h,scale_factor=0,file_do_cache=false} end
    end
    if self.textbox then self.textbox:free() end
    self.textbox=self:makeText(state.text or '',self.language_code,self.dimen.w-2*self.margin,self.lower.h-self.bar-2*self.margin)
    -- top_line_num is only honored by editable TextBoxWidgets. Restore the
    -- read-only view through its page API instead.
    while self.textbox.virtual_line_num < (state.line or 1)
        and self.textbox.virtual_line_num+self.textbox.lines_per_page<=#self.textbox.vertical_string_list do
        self.textbox:scrollDown()
    end
    if self.footer then for _,button in ipairs(self.footer) do button.label:free() end end
    self.footer={}
    local labels=self.language_code=='ja' and {'戻る','メニュー','次へ'} or {'Back','Menu','Next'}
    for i,label in ipairs(labels) do
        local left=math.floor((i-1)*self.dimen.w/3)
        local width=math.floor(i*self.dimen.w/3)-left
        self.footer[i]={x=left,w=width,label=TextWidget:new{text=label,face=Font:getFace('cfont',18),
            fgcolor=self:colors(),max_width=width-2*self.margin}}
    end
    self.display_ready=true;self.display_image=state.image;self.display_text=text_key
    if first or full_refresh then
        self.text_refreshes=0;self.image_refreshes=0
        UIManager:setDirty(self,'full',self.dimen,true)
    else
        if update_image then self:refreshRegion(true) end
        if update_text then self:refreshRegion(false) end
    end
end
function Player:onShow() UIManager:setDirty(self,'full',self.dimen,true) end
function Player:paintTo(bb,x,y)
    local fg,bg=self:colors()
    bb:paintRect(x,y+self.top,self.dimen.w,self.upper.h,Blitbuffer.COLOR_BLACK)
    if self.picture then
        local size=self.picture:getSize()
        self.picture:paintTo(bb,x+math.floor((self.dimen.w-size.w)/2),y+self.top+math.floor((self.upper.h-size.h)/2))
    end
    bb:paintRect(x,y+self.split,self.dimen.w,self.dimen.h-self.split,bg)
    self.textbox:paintTo(bb,x+self.margin,y+self.split+self.margin)
    bb:paintRect(x,y+self.dimen.h-self.bar,self.dimen.w,1,fg)
    for i,button in ipairs(self.footer) do
        local size=button.label:getSize()
        if i>1 then bb:paintRect(x+button.x,y+self.dimen.h-self.bar,1,self.bar,fg) end
        button.label:paintTo(bb,x+button.x+math.floor((button.w-size.w)/2),
            y+self.dimen.h-self.bar+math.floor((self.bar-size.h)/2))
    end
end
function Player:onNext()
    if self.suspended then return true end
    if self.textbox and self.boundary and self.textbox.virtual_line_num+self.textbox.lines_per_page-1<#self.textbox.vertical_string_list then
        self.textbox:scrollDown();self.engine.state.line=self.textbox.virtual_line_num
        self:refreshRegion(false);self:save('auto');return true
    end
    if not self.finished then self:advance() end
    return true
end
function Player:onPrevious()
        if self.textbox and self.textbox.virtual_line_num>1 then
        self.textbox:scrollUp();self.engine.state.line=self.textbox.virtual_line_num
        self:refreshRegion(false);self:save('auto');return true
    end
    if #self.history>1 then
        self:cancel();table.remove(self.history);local last=self.history[#self.history]
        self.engine:restore(last.state);self.finished=last.finished;self.boundary=true
        self:restoreAudio(last.positions);self:render(true);self:save('auto')
    end
    return true
end
function Player:onTap(_,ges)
    if ges.pos.y<self.top then return false end
    if ges.pos.y>=self.dimen.h-self.bar then
        for i,button in ipairs(self.footer) do
            if ges.pos.x>=button.x and ges.pos.x<button.x+button.w then
                if i==1 then return self:onPrevious() elseif i==2 then return self:onMenu() else return self:onNext() end
            end
        end
        return true
    end
    if ges.pos.y<self.split then return self:onMenu() end
    return self:onNext()
end
function Player:onSwipe(_,ges)
    if ges.pos and ges.pos.y<self.top then return false end
    if ges.direction=='west' then return self:onNext() elseif ges.direction=='east' then return self:onPrevious() end
    return true
end
function Player:buttons(title,rows)
    local dialog
    local buttons={}
    for _,row in ipairs(rows) do
        local out={}
        for _,item in ipairs(row) do
            local action=item[2]
            out[#out+1]={text=item[1],callback=function() UIManager:close(dialog);action() end}
        end
        buttons[#buttons+1]=out
    end
    buttons[#buttons+1]={{text='Close',callback=function() UIManager:close(dialog) end}}
    dialog=ButtonDialog:new{title=title,buttons=buttons}
    UIManager:show(dialog)
end
function Player:slots(write)
    local rows={}
    for i=1,6 do
        local slot='slot'..i;local saved=Storage.load(SAVE..'/'..slot..'.json')
        local label=i..': '..(saved and (saved.language..' · '..saved.time) or 'Empty')
        rows[#rows+1]={{label,function()
            if not write then self:load(slot)
            elseif saved then UIManager:show(ConfirmBox:new{text='Replace this saved game?',ok_callback=function() self:save(slot) end})
            elseif self:save(slot) then info('Game saved.') end
        end}}
    end
    self:buttons(write and 'Save game' or 'Load game',rows)
end
function Player:chapters()
    local rows={}
    for n,c in ipairs(self.engine.story.chapters) do
        local number=n
        rows[#rows+1]={{n..' · '..c.title,function()
            self:cancel();self.audio:close();self.history={};self.engine:chapter(number);self.finished=false;self:advance()
        end}}
    end
    self:buttons('Chapters',rows)
end
function Player:preferences()
    Storage.save(SAVE..'/preferences.json',self.prefs)
end
function Player:readingOptions()
    self:buttons('Reading settings',{
        {{'Text −',function() self:fontSize(-2) end},{'Text +',function() self:fontSize(2) end}},
        {{self.prefs.furigana and 'Furigana: on' or 'Furigana: off',function()
            self.prefs.furigana=not self.prefs.furigana;self.engine.state.line=1;self:preferences();self:render(false)
        end}},
    })
end
function Player:onMenu(_,ges)
    if ges and ges.pos and ges.pos.y<self.top then return false end
    if self.pending then
        self:cancel();self.boundary=true;self:render(false)
    end
    self:buttons('Narcissu',{
        {{'Save',function() self:slots(true) end},{'Load',function() self:slots(false) end}},
        {{'Chapters',function() self:chapters() end},{'Full refresh',function() self:render(true,true) end}},
        {{'English',function() self:changeLanguage('en') end},{'日本語',function() self:changeLanguage('ja') end}},
        {{self:dark() and 'Light mode' or 'Dark mode',function()
            self.prefs.dark=not self:dark();self:preferences();self:render(false,true)
        end},{'Reading settings',function() self:readingOptions() end}},
        {{'Backlight',function() self:backlight() end}},
        {{(self.audio.muted or self.audio.disabled) and 'Unmute' or 'Mute',function() self:mute() end},{'Replay voice line',function() self:replayVoice() end}},
        {{'Save and exit',function() self:onQuit() end}},
    });return true
end
function Player:changeLanguage(lang)
    if lang==self.language_code then return end
    UIManager:show(ConfirmBox:new{text='Changing language restarts the current chapter. Continue?',ok_callback=function()
        local chapter=self.engine.state.chapter
        self:cancel();self.audio:close();self.language_code=lang;self.history={}
        self.engine=Engine.new(assert(Storage.read(DATA..'/'..lang..'.json')));self.engine:chapter(chapter);self.finished=false;self:advance()
    end})
end
function Player:fontSize(delta)
    self.prefs.font=math.max(16,math.min(40,self.prefs.font+delta));self.engine.state.line=1
    self:render(false);self:preferences();self:save('auto')
end
function Player:onSuspend()
    self:save('auto');self:cancel();self.suspended=true;self.audio:pause(true)
end
function Player:onResume()
    self.suspended=false;self.audio:pause(false);self:render(true,true)
    if not self.boundary then self:advance() end
end
function Player:onQuit()
    self:save('auto');UIManager:close(self);return true
end
function Player:onClose() return self:onQuit() end
function Player:onExit() self:onQuit() end
function Player:onRestart() self:onQuit() end
function Player:onCloseWidget()
    if self.closed then return end
    self:save('auto');self.closed=true;self:cancel();UIManager:unschedule(self.tick);self.audio:close()
    os.remove(SAVE..'/audio-session.json')
    if self.picture then self.picture:free() end
    if self.textbox then self.textbox:free() end
    if self.footer then for _,button in ipairs(self.footer) do button.label:free() end end
    if self.owner then self.owner.player=nil end
    UIManager:setDirty('all','full')
end
local Plugin=WidgetContainer:extend{name='narcissu',is_doc_only=false}
function Plugin:init() self.ui.menu:registerToMainMenu(self) end
function Plugin:addToMainMenu(items)
    items.narcissu={text='Narcissu',sorting_hint='more_tools',callback=function() self:open() end}
end
function Plugin:open()
    if self.player then return end
    if not Storage.read(DATA..'/media.json') then info('Game data is missing. Install the complete Narcissu package in koreader/plugins/narcissu.koplugin/.');return end
    local saved=Storage.load(SAVE..'/auto.json')
    local ok,player=pcall(function() return Player:new{owner=self,language_code=saved and saved.language or 'en',initial_save=saved} end)
    if not ok then info('Narcissu could not start: '..tostring(player));return end
    self.player=player;UIManager:show(player)
    if player.audio.disabled then
        info('The previous audio session ended unexpectedly. Audio is off for this session; select Menu > Unmute to resume it.')
    elseif not player.audio.available then info('Bluetooth audio is unavailable on this firmware. Reading and saves are still available.') end
end
function Plugin:onSuspend() if self.player then self.player:onSuspend() end end
function Plugin:onResume() if self.player then self.player:onResume() end end
function Plugin:onExit() if self.player then self.player:onQuit() end end
function Plugin:onRestart() if self.player then self.player:onQuit() end end
function Plugin:onCloseWidget() if self.player then self.player:onQuit() end end
return Plugin
