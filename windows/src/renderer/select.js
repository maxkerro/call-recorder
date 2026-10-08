'use strict';
// Region picker: shows the frozen screen dimmed; drag a rectangle; the area inside is shown at full brightness.
const bg = document.getElementById('bg'), box = document.getElementById('box'), hot = document.getElementById('hot');
let start = null, rect = null;

window.sel.onInit((url) => { bg.style.backgroundImage = `url("${url}")`; hot.style.backgroundImage = `url("${url}")`; });

const norm = (a, b) => ({ x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), w: Math.abs(a.x - b.x), h: Math.abs(a.y - b.y) });

function draw(r) {
  box.style.display = hot.style.display = 'block';
  Object.assign(box.style, { left: r.x + 'px', top: r.y + 'px', width: r.w + 'px', height: r.h + 'px' });
  Object.assign(hot.style, { left: -r.x - 2 + 'px', top: -r.y - 2 + 'px' });   // -2: the box border
}

addEventListener('mousedown', (e) => { if (e.button === 0) { start = { x: e.clientX, y: e.clientY }; rect = null; } });
addEventListener('mousemove', (e) => { if (start) { rect = norm(start, { x: e.clientX, y: e.clientY }); draw(rect); } });
addEventListener('mouseup', () => {
  if (!start) return;
  start = null;
  if (rect && rect.w >= 12 && rect.h >= 12) window.sel.done({ ...rect, vw: innerWidth, vh: innerHeight });
  else { rect = null; box.style.display = 'none'; }          // a click without a drag: try again
});
addEventListener('keydown', (e) => { if (e.key === 'Escape') window.sel.done(null); });
addEventListener('contextmenu', (e) => { e.preventDefault(); window.sel.done(null); });
