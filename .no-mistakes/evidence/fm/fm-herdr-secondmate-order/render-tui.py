from pathlib import Path
import sys,html
sys.path.insert(0,str(Path.cwd()/'.test-phase/vendor'))
import pyte
class Screen(pyte.Screen):
 def report_device_status(self,*args,**kwargs): pass
base=Path('/Users/christianalexanderdiaz/.no-mistakes/evidence/01M46QDNV1250V3J2NJPF2GK3V')
screen=Screen(120,40); stream=pyte.Stream(screen)
raw=(base/'sidebar.ansi').read_bytes().decode('utf-8','replace'); stream.feed(raw)
text='\n'.join(screen.display); (base/'sidebar-screen.txt').write_text(text)
colors={'default':'#eeeeee','black':'#111111','red':'#ff5555','green':'#55cc77','brown':'#ccb755','blue':'#7788ff','magenta':'#cc88dd','cyan':'#66dddd','white':'#eeeeee','brightblack':'#888888'}
rows=[]
for row in range(40):
 chars=[]
 for col in range(120):
  cell=screen.buffer[row][col]
  if cell.data=='': continue # second grid cell of a wide character
  fg=colors.get(cell.fg,'#'+cell.fg); bg=colors.get(cell.bg,'#'+cell.bg) if cell.bg!='default' else '#111111'
  chars.append(f'<span style="color:{fg};background:{bg};'+('font-weight:bold;' if cell.bold else '')+'">'+html.escape(cell.data)+'</span>')
 rows.append(''.join(chars))
(base/'sidebar.html').write_text('<!doctype html><html><meta charset="utf-8"><title>Real Herdr lab sidebar</title><body style="margin:0;background:#111"><pre style="font:14px/18px monospace;white-space:pre">'+'\n'.join(rows)+'</pre></body></html>')
print(text)
