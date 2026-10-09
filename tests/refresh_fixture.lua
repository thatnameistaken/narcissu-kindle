-- Execute the actual Player render and pagination methods with widget stubs.
-- This verifies requested refresh regions; it does not emulate a physical panel.
return function(source,w,h,pagination)
    local calls={}
    local widget={new=function(_,o)
        o.virtual_line_num=1;o.lines_per_page=5;o.vertical_string_list={}
        for i=1,100 do o.vertical_string_list[i]=true end
        o.free=function() end
        o.scrollDown=function(s) s.virtual_line_num=s.virtual_line_num+5 end
        o.scrollUp=function(s) s.virtual_line_num=math.max(1,s.virtual_line_num-5) end
        return o
    end}
    local env=setmetatable({Player={},ROOT='.',DATA='.',
        UIManager={setDirty=function(_,player,mode,region,dither) calls[#calls+1]={mode=mode,region=region,dither=dither} end},
        TextBoxWidget=widget,TextWidget=widget,ImageWidget=widget,
        Screen={},Font={getFace=function() return {} end}}, {__index=_G})
    local code=source:match('(function Player:refreshRegion.-)function Player:paintTo')
    assert(code)
    if pagination then code=code..assert(source:match('(function Player:onNext.-)function Player:onTap')) end
    local f=assert(loadstring(code));setfenv(f,env);f()
    local p=setmetatable({dimen={w=w,h=h},split=math.floor(h/2),margin=20,bar=54,prefs={font=24},language_code='en',media={},
        engine={state={text='First passage',chapter=1,line=1},story={chapters={{title='Chapter'}}}}},{__index=env.Player})
    p.upper={x=0,y=0,w=w,h=p.split};p.lower={x=0,y=p.split,w=w,h=h-p.split}
    p.dark=function() return false end;p.colors=function() return 0,255 end
    p.makeText=function(_,text,lang,width,height) return widget:new{text=text,width=width,height=height} end
    p:render(true);assert(#calls==1 and calls[1].mode=='full')
    local function clear() for k in pairs(calls) do calls[k]=nil end end
    local function region(image,mode)
        assert(#calls==1,'Expected one region, got '..#calls)
        local c=calls[1];local r=c.region
        assert(c.mode==mode and r.x==0 and r.w==w)
        assert(r.y==(image and 0 or p.split))
        assert(r.h==(image and p.split or h-p.split))
        assert(c.dither==image)
    end
    clear()
    if pagination then
        p.boundary=true;p.save=function() return true end
        for i=1,8 do p:onNext();region(false,i==8 and 'flashui' or 'ui');clear() end
        p:onPrevious();region(false,'ui');return true
    end
    p:render(true);assert(#calls==0,'Unchanged scene must not refresh')
    for i=1,8 do
        p.engine.state.text='Passage '..i;p:render(false)
        region(false,i==8 and 'flashui' or 'ui');clear()
    end
    for i=1,6 do
        local key='image'..i;p.media[key]={file=key..'.png'};p.engine.state.image=key;p:render(true)
        region(true,i==6 and 'flashui' or 'ui');clear()
    end
    p.engine.state.text='Loaded passage';p.engine.state.image=nil;p:render(true)
    assert(#calls==2 and calls[1].region==p.upper and calls[2].region==p.lower)
    assert(calls[1].mode~='full' and calls[2].mode~='full');clear()
    p:render(true,true);assert(#calls==1 and calls[1].mode=='full')
    assert(p.image_refreshes==0 and p.text_refreshes==0)
    return true
end
