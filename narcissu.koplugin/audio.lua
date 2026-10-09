-- Isolated stock GStreamer playback: never load native audio libraries in KOReader.
local ffi=require('ffi')
ffi.cdef[[int getpid(void); int kill(int pid,int sig);]]
local lfs=require('libs/libkoreader-lfs')
local ROOT=debug.getinfo(1,'S').source:sub(2):match('^(.*)/[^/]+$')
local Audio={};Audio.__index=Audio
local sequence=0
local function quote(s)
    assert(not s:find('[%z\r\n]'),'Invalid audio path')
    return "'"..s:gsub("'","'\\''").."'"
end
local function read(path)
    local f=io.open(path,'rb');if not f then return nil end
    local size=f:seek('end');f:seek('set',math.max(0,(size or 0)-8192))
    local value=f:read('*a');f:close();return value
end
local function exists(path) local f=io.open(path,'rb');if f then f:close();return true end end
function Audio.new(root,media,onerror,options)
    local a=setmetatable({root=root,media=media,channels={},voice=true,onerror=onerror,events={},software_volume=false},Audio)
    if options and options.disabled then a.disabled=true;a.error='Audio is off. Select Menu > Unmute to resume it.';return a end
    for _,candidate in ipairs({{'/usr/bin/gst-launch-0.10',true},{'/usr/bin/gst-launch-1.0',false},{'/usr/bin/gst-launch'}}) do
        if exists(candidate[1]) then
            a.gst=candidate[1];a.old=candidate[2]
            if a.old==nil then
                local f=io.popen('LD_LIBRARY_PATH= LD_PRELOAD= '..quote(a.gst)..' --version 2>/dev/null')
                local version=f and f:read('*a') or '';if f then f:close() end
                if version:find('0.10',1,true) then a.old=true
                elseif version:find('1.',1,true) then a.old=false
                else a.gst=nil end
            end
            if a.gst then break end
        end
    end
    if not a.gst then a.error='Stock GStreamer unavailable: no supported gst-launch executable found';return a end
    a.parent=tonumber(ffi.C.getpid());a.temp='/tmp/narcissu-audio-'..a.parent
    lfs.mkdir(a.temp)
    a.libname='Isolated '..a.gst;a.available=true;a:focus()
    return a
end
function Audio:focus()
    if exists('/usr/bin/lipc-set-prop') then
        local result=os.execute('LD_LIBRARY_PATH= LD_PRELOAD= /usr/bin/lipc-set-prop com.lab126.audiomgrd setFocus Music >/dev/null 2>&1')
        self:record((result==0 or result==true) and 'Music output focus requested' or 'Music output focus request failed')
    else self:record('Music focus command unavailable') end
end
function Audio:record(message)
    self.events[#self.events+1]=os.date('%H:%M:%S')..' '..message
    if #self.events>20 then table.remove(self.events,1) end
    if self.log_path then local f=io.open(self.log_path,'w');if f then f:write(self:status());f:close() end end
end
function Audio:report(message) self.error=message;self:record('ERROR '..message);if self.onerror then self.onerror(message) end end
function Audio:status()
    local lines={self.disabled and 'Audio disabled; no audio process started.' or self.libname or self.error or 'Audio unavailable',
        'Muted: '..tostring(self.muted==true)..' · Voice: '..tostring(self.voice),
        'Use Kindle/headphone volume controls.'}
    local active={}
    for key,ch in pairs(self.channels) do active[#active+1]=key..': '..self.media[ch.asset].original end
    table.sort(active);lines[#lines+1]=#active>0 and table.concat(active,'\n') or 'No active streams.'
    if self.error then lines[#lines+1]='Last error: '..self.error end
    lines[#lines+1]=table.concat(self.events,'\n');return table.concat(lines,'\n')
end
function Audio:spawn(channel,ch)
    local m=self.media[ch.asset];sequence=sequence+1
    ch.prefix=self.temp..'/'..sequence;ch.loops=0;ch.elapsed=0
    local minimum=math.max(1,math.floor((m.duration+(m.lead_in or 0)+(m.tail or 0))*0.5))
    local args={ROOT..'/audio-runner.sh',self.gst,self.old and '1' or '0',self.root..'/'..m.file,
        tostring(m.rate),tostring(m.channels or 2),ch.loop and '1' or '0',ch.prefix,tostring(self.parent),tostring(minimum)}
    for i,v in ipairs(args) do args[i]=quote(v) end
    local cmd='LD_LIBRARY_PATH= LD_PRELOAD= /bin/sh '..table.concat(args,' ')..' >/dev/null 2>&1 &'
    local result=os.execute(cmd)
    if result~=0 and result~=true then self:report(channel..': could not start stock audio process');return false end
    self:record('Start '..channel..' '..m.original..' '..m.rate..'Hz; Music sync=true')
    return true
end
function Audio:play(channel,asset,loop,position)
    self:stop(channel)
    if not self.available or self.muted then return false end
    local m=self.media[asset]
    if not m or m.kind~='audio' then self:report('Missing audio asset: '..tostring(asset));return false end
    if m.original:match('^w/') and not self.voice then return false end
    if not exists(self.root..'/'..m.file) then self:report('Missing audio file: '..m.original);return false end
    local ch={asset=asset,loop=loop,elapsed=0};self.channels[channel]=ch
    if position and position>0 then self:record('Restored audio restarts at the beginning: '..m.original) end
    if not self.paused and not self:spawn(channel,ch) then self.channels[channel]=nil;return false end
    return true
end
function Audio:release(ch)
    if not ch.prefix then return end
    -- Cancellation file covers a stop that arrives before the shell writes its PID.
    local f=io.open(ch.prefix..'.cancel','w');if f then f:write('stop');f:close() end
    local pid=tonumber(read(ch.prefix..'.pid'))
    if pid then
        local cmdline=read('/proc/'..pid..'/cmdline')
        if cmdline and cmdline:find(ch.prefix,1,true) then ffi.C.kill(pid,15) end
    end
    ch.prefix=nil
end
function Audio:stop(channel)
    local ch=self.channels[channel];if ch then self:release(ch);self.channels[channel]=nil end
end
function Audio:tick(dt)
    if not self.available or self.paused then return end
    local remove={}
    for channel,ch in pairs(self.channels) do
        ch.elapsed=ch.elapsed+dt
        local done=read(ch.prefix..'.done')
        if done then
            local code=tonumber(done)
            if code~=0 then self:report(channel..' ('..self.media[ch.asset].original..'): exit '..tostring(code)..'\n'..(read(ch.prefix..'.log') or 'No pipeline log'))
            else self:record('Complete '..channel..' '..self.media[ch.asset].original) end
            remove[#remove+1]=channel
        else
            local loops=tonumber(read(ch.prefix..'.loops')) or 0
            if loops>ch.loops then ch.loops=loops;ch.elapsed=0;self:record('Loop '..channel..' #'..loops) end
            local pid=tonumber(read(ch.prefix..'.pid'))
            if ch.elapsed>5 and (not pid or ffi.C.kill(pid,0)~=0) then
                self:report(channel..': audio process ended without a completion record\n'..(read(ch.prefix..'.log') or 'No pipeline log'))
                remove[#remove+1]=channel
            end
        end
    end
    for _,channel in ipairs(remove) do self:stop(channel) end
end
function Audio:position(ch)
    local m=self.media[ch.asset]
    return math.max(0,math.min(m.duration,(ch.elapsed or 0)-(m.lead_in or 0)))
end
function Audio:positions() local result={};for channel,ch in pairs(self.channels) do result[channel]=self:position(ch) end;return result end
function Audio:voiceBusy()
    if self.muted or self.paused then return false end
    for _,ch in pairs(self.channels) do if self.media[ch.asset].original:match('^w/') then return true end end
    return false
end
function Audio:setMuted(value) self.muted=value;if value then self:close() end end
function Audio:pause(value)
    if self.paused==value then return end
    self.paused=value
    if value then for _,ch in pairs(self.channels) do self:release(ch) end
    else
        if self.available then self:focus() end
        local remove={};for channel,ch in pairs(self.channels) do if not self:spawn(channel,ch) then remove[#remove+1]=channel end end
        for _,channel in ipairs(remove) do self:stop(channel) end
    end
end
function Audio:close()
    local keys={};for key in pairs(self.channels) do keys[#keys+1]=key end
    for _,key in ipairs(keys) do self:stop(key) end
end
return Audio
