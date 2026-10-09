-- Pure state machine, independent of KOReader and audio hardware.
local Engine = {}
Engine.__index = Engine
local function copy(t)
    if type(t) ~= "table" then return t end
    local r = {}; for k,v in pairs(t) do r[k] = copy(v) end; return r
end
function Engine.new(story)
    assert(story.format == 1, "Unsupported story format")
    return setmetatable({story=story, state={pc=1,chapter=1,text="",audio={},line=1}},Engine)
end
function Engine:snapshot() return copy(self.state) end
function Engine:restore(s)
    assert(type(s)=="table" and type(s.pc)=="number" and s.pc%1==0 and s.pc>=1 and s.pc<=#self.story.events+1,"Invalid save position")
    assert(type(s.text)=="string" and type(s.audio)=="table","Invalid save state")
    assert(type(s.chapter)=='number' and s.chapter%1==0 and self.story.chapters[s.chapter],'Invalid saved chapter')
    assert(type(s.line)=='number' and s.line>=1 and s.line%1==0,'Invalid saved text position')
    for channel,a in pairs(s.audio) do
        assert(type(channel)=='string' and type(a)=='table' and type(a.asset)=='string','Invalid saved audio')
    end
    self.state=copy(s)
end
function Engine:chapter(n)
    assert(self.story.chapters[n],"Invalid chapter")
    self.state={pc=self.story.chapters[n].index,chapter=n,text="",audio={},line=1}
end
function Engine:step()
    local s=self.state
    local e=self.story.events[s.pc]
    if not e then return {op="end"} end
    s.pc=s.pc+1
    if e.op=="chapter" then s.chapter=e.number;s.text="";s.line=1
    elseif e.op=="image" then s.image=e.asset
    elseif e.op=="audio" then s.audio[e.channel]={asset=e.asset,loop=e.loop}
    elseif e.op=="stop" then s.audio[e.channel]=nil
    elseif e.op=="text" then
        s.text=e.clear and e.text or (s.text.."\n"..e.text);s.line=1
    end
    return e
end
Engine.copy=copy
return Engine
