local Reading={}
function Reading.chars(text)
    local result={}
    for c in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do result[#result+1]=c end
    return result
end
return Reading
