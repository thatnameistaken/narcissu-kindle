-- Small platform stubs exercise the actual widget and controller code.
return function(root)
    local Reading=dofile(root..'/reading.lua')
    assert(#Reading.chars('あa字')==3)
    local Widget={}
    function Widget:extend(o) return setmetatable(o,{__index=self}) end
    function Widget:new(o) o=setmetatable(o or {},{__index=self});if o.init then o:init() end;return o end
    local Text=Widget:extend{}
    function Text:getSize() return {w=#Reading.chars(self.text)*self.face,h=self.face+2} end
    local paints={}
    function Text:paintTo(_,x,y) paints[#paints+1]={x=x,y=y,w=self:getSize().w,h=self:getSize().h} end
    function Text:free() self.freed=true end
    package.loaded['ui/widget/widget']=Widget
    package.loaded['ui/widget/textwidget']=Text
    package.loaded['ui/font']={getFace=function(_,_,size) return size end}
    local screen={scaleBySize=function(_,n) return n end,getWidth=function() return 600 end,getHeight=function() return 800 end}
    package.loaded.device={screen=screen}
    local Ruby=dofile(root..'/rubywidget.lua')
    for _,w in ipairs({240,560,1364,1820}) do
        local tokens={}
        for _=1,80 do tokens[#tokens+1]={base='病院',reading='びょういん'};tokens[#tokens+1]={base='へ。'} end
        local r=Ruby:new{tokens=tokens,width=w,height=220,font_size=40}
        assert(r.lines_per_page>0)
        for _,row in ipairs(r.vertical_string_list) do
            local width=0;for _,c in ipairs(row) do width=width+c.w end
            assert(width<=w,'Ruby row overflows: '..width..' > '..w)
        end
        paints={};r:paintTo({},0,0)
        for _,p in ipairs(paints) do assert(p.x>=0 and p.x+p.w<=w and p.y+p.h<=220) end
        local first=r:getVisibleText();r:scrollDown();assert(r.virtual_line_num>1);r:scrollUp();assert(r:getVisibleText()==first)
        r:free();assert(#r.cells==0)
    end
    return true
end
