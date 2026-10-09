local Widget=require('ui/widget/widget')
local TextWidget=require('ui/widget/textwidget')
local Font=require('ui/font')
local Screen=require('device').screen
local ROOT=debug.getinfo(1,'S').source:sub(2):match('^(.*)/[^/]+$')
local Reading=dofile(ROOT..'/reading.lua')
local Ruby=Widget:extend{}
function Ruby:init()
    self.virtual_line_num=1;self.vertical_string_list={{}};self.cells={}
    local base_size=self.font_size or 24;local ruby_size=math.max(8,math.floor(base_size*0.5))
    local function tw(text,size)
        return TextWidget:new{text=text,face=Font:getFace('cfont',size),fgcolor=self.fgcolor,padding=0,lang='ja',use_xtext=true}
    end
    local probe=tw('字',base_size);self.base_h=probe:getSize().h;probe:free()
    probe=tw('じ',ruby_size);self.ruby_h=probe:getSize().h;probe:free()
    self.line_h=self.base_h+self.ruby_h+Screen:scaleBySize(4)
    self.lines_per_page=math.max(1,math.floor(self.height/self.line_h))
    local row=self.vertical_string_list[1];local used=0
    local function newrow() row={};self.vertical_string_list[#self.vertical_string_list+1]=row;used=0 end
    local function cell(base,reading)
        if base=='\n' then newrow();return end
        local size=base_size;local b,r,bw,rw,sz
        repeat
            if b then b:free() end;if r then r:free() end
            b=tw(base,size);r=reading and tw(reading,math.max(6,math.floor(size*0.5))) or nil
            bw=b:getSize().w;rw=r and r:getSize().w or 0;sz=math.max(bw,rw)
            if sz<=self.width or size<=6 then break end
            size=size-1
        until false
        local c={base=base,b=b,r=r,bw=bw,rw=rw,w=sz}
        if used+sz>self.width and #row>0 then
            -- Avoid stranding common closing punctuation at the start of a line.
            local closing=('、。，．！？：；）」』】〕〉》'):find(base,1,true)
            local opening=('（「『【〔〈《'):find(row[#row].base,1,true)
            if (closing or opening) and #row>1 then
                local previous=table.remove(row);newrow();row[1]=previous;used=previous.w
            else newrow() end
        end
        row[#row+1]=c;used=used+sz;self.cells[#self.cells+1]=c
    end
    for _,token in ipairs(self.tokens or {{base=self.text or ''}}) do
        if token.reading and token.reading~='' then cell(token.base,token.reading)
        else for _,c in ipairs(Reading.chars(token.base)) do cell(c) end end
    end
end
function Ruby:scrollDown()
    if self.virtual_line_num+self.lines_per_page<=#self.vertical_string_list then self.virtual_line_num=self.virtual_line_num+self.lines_per_page end
end
function Ruby:scrollUp() self.virtual_line_num=math.max(1,self.virtual_line_num-self.lines_per_page) end
function Ruby:getVisibleText()
    local result={}
    for i=self.virtual_line_num,math.min(#self.vertical_string_list,self.virtual_line_num+self.lines_per_page-1) do
        for _,c in ipairs(self.vertical_string_list[i]) do result[#result+1]=c.base end
        result[#result+1]='\n'
    end
    return table.concat(result)
end
function Ruby:paintTo(bb,x,y)
    for i=self.virtual_line_num,math.min(#self.vertical_string_list,self.virtual_line_num+self.lines_per_page-1) do
        local dx=x;local dy=y+(i-self.virtual_line_num)*self.line_h
        for _,c in ipairs(self.vertical_string_list[i]) do
            if c.r then c.r:paintTo(bb,dx+math.floor((c.w-c.rw)/2),dy) end
            c.b:paintTo(bb,dx+math.floor((c.w-c.bw)/2),dy+self.ruby_h)
            dx=dx+c.w
        end
    end
end
function Ruby:free()
    for _,c in ipairs(self.cells or {}) do c.b:free();if c.r then c.r:free() end end
    self.cells={}
end
return Ruby
