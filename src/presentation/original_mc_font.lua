-- Lazy lookup in the original MC unihex atlas. The complete binary index is
-- loaded once; only characters actually displayed allocate glyph records.
local M={};local cache={}
function M.attach(assets,directory,records)
  if not assets.unicode_font then return end
  local function read(path)
    assert(type(path)=='string' and not path:find('..',1,true) and not path:find(':',1,true),'invalid-font-path')
    local record=assert(records[path],'unlisted-original-font')
    local f=assert(io.open(directory..'/'..path,'rb'));local raw=f:read('*a');f:close()
    assert(require('storage.sha256')(raw)==record.sha256,'original-font-hash-mismatch')
    return raw
  end
  local header_path=assets.unicode_font.index
  local header=assert(require('dkjson').decode(read(header_path)))
  assert(header.schema==1 and header.record_bytes==12 and header.count==assets.unicode_font.count
    and header.count>0 and header.count<200000 and type(header.pages)=='table','original-font-schema')
  local key=directory..'/'..assert(records[header_path]).sha256..'/'..assert(records[header.index]).sha256
  local font=cache[key]
  if not font then
    local binary=read(header.index)
    assert(#binary==header.count*12,'original-font-index-size')
    for _,page in ipairs(header.pages)do assert(records[page],'original-font-page-unlisted')end
    font={header=header,binary=binary,glyphs={}};cache[key]=font
  end
  setmetatable(assets.glyphs,{__index=function(_,character)
    local known=font.glyphs[character];if known~=nil then return known or nil end
    if type(character)~='string' or utf8.len(character)~=1 then return end
    local code=utf8.codepoint(character);local lo,hi=1,font.header.count
    while lo<=hi do
      local index=(lo+hi)//2
      local cp,page,x,y,w,h=string.unpack('<I4I2I2I2BB',font.binary,(index-1)*12+1)
      if code<cp then hi=index-1 elseif code>cp then lo=index+1 else
        assert(w>0 and w<=32 and h>0 and h<=16 and x+w<=2048 and y+h<=2048,'original-font-glyph-bounds')
        local glyph={path=assert(font.header.pages[page]),width=w/2,height=h/2,advance=w/2+1,
          region={x=x,y=y,w=w,h=h,tw=2048,th=2048}}
        font.glyphs[character]=glyph;return glyph
      end
    end
    font.glyphs[character]=false
  end})
end
return M
