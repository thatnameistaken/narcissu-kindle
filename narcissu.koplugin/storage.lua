local JSON=require('rapidjson')
local Storage={}
function Storage.read(path)
    local f=io.open(path,'rb');if not f then return nil end
    local data=f:read('*a');f:close()
    local ok,result=pcall(JSON.decode,data or '')
    if ok and type(result)=='table' then return result end
end
function Storage.load(path) return Storage.read(path) or Storage.read(path..'.bak') end
function Storage.save(path,value)
    local ok,data=pcall(JSON.encode,value);if not ok then return nil,data end
    local f,err=io.open(path..'.tmp','wb');if not f then return nil,err end
    local wrote,e=f:write(data);local closed,ce=f:close()
    if not wrote or not closed then os.remove(path..'.tmp');return nil,e or ce end
    -- Keep the last valid generation. A power loss during replacement leaves
    -- either the current file or the backup readable on FAT storage.
    local old=io.open(path,'rb')
    if old then
        old:close();os.remove(path..'.bak')
        local moved,me=os.rename(path,path..'.bak')
        if not moved then return nil,me end
    end
    local moved,me=os.rename(path..'.tmp',path)
    if not moved then os.rename(path..'.bak',path);return nil,me end
    return true
end
return Storage
