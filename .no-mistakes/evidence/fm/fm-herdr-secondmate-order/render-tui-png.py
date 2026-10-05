exec(open('.test-phase/render-tui.py').read().split('print(text)')[0])
from PIL import Image, ImageDraw, ImageFont
image=Image.new('RGB',(1200,800),'#111111'); draw=ImageDraw.Draw(image); font=ImageFont.load_default(size=16)
for y in range(40):
 for x in range(120):
  cell=screen.buffer[y][x]
  if cell.data=='': continue
  fg=colors.get(cell.fg,'#'+cell.fg); bg=colors.get(cell.bg,'#'+cell.bg) if cell.bg!='default' else '#111111'
  if cell.reverse: fg,bg=bg,fg
  if bg!='#111111': draw.rectangle((x*10,y*20,(x+1)*10,(y+1)*20),fill=bg)
  draw.text((x*10,y*20),cell.data,font=font,fill=fg)
image.save(base/'sidebar.png')
