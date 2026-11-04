// Runs only in an isolated main-frame world. Inputs: options JSON and native viewport size.
const p = JSON.parse(options);
const has = key => Object.prototype.hasOwnProperty.call(p, key);
const fail = (code, message, data) => JSON.stringify({error:{code,message,data}});
const finite = n => typeof n === 'number' && Number.isFinite(n);
if (has('rect') && has('selector'))
    return fail(-32602, 'rect and selector are mutually exclusive; provide only one');
if (has('padding') && !has('rect') && !has('selector'))
    return fail(-32602, 'padding requires rect or selector');
const padding = has('padding') ? p.padding : 0;
if (!finite(padding) || padding < 0)
    return fail(-32602, 'padding must be a finite nonnegative number');
if (!(viewportWidth > 0 && viewportHeight > 0 && innerWidth > 0 && innerHeight > 0))
    return fail(-32004, 'Viewport has no visible area');
const sx = viewportWidth / innerWidth, sy = viewportHeight / innerHeight;
let r = {x:0,y:0,width:viewportWidth,height:viewportHeight};
if (has('rect')) r = p.rect;
if (has('selector')) {
    if (typeof p.selector !== 'string' || !p.selector.length)
        return fail(-32602, 'selector must be a nonempty CSS selector string');
    let element;
    try { element = document.querySelector(p.selector); }
    catch (_) { return fail(-32602, 'Invalid CSS selector: ' + p.selector, {selector:p.selector}); }
    if (!element) return fail(-32004, 'No element matches selector: ' + p.selector, {selector:p.selector});
    const b = element.getBoundingClientRect();
    r = {x:b.x*sx,y:b.y*sy,width:b.width*sx,height:b.height*sy};
}
if (!r || typeof r !== 'object' || !['x','y','width','height'].every(k => finite(r[k])) || r.width <= 0 || r.height <= 0)
    return fail(-32602, 'rect requires finite x/y and positive width/height');
let left = r.x-padding, top = r.y-padding, right = r.x+r.width+padding, bottom = r.y+r.height+padding;
if (![left,top,right,bottom].every(finite)) return fail(-32602, 'Screenshot region is not finite');
left = Math.max(0,left); top = Math.max(0,top);
right = Math.min(viewportWidth,right); bottom = Math.min(viewportHeight,bottom);
if (right <= left || bottom <= top) return fail(-32602, 'Screenshot region has no viewport intersection after padding');
left = Math.floor(left); top = Math.floor(top);
right = Math.min(viewportWidth,Math.ceil(right)); bottom = Math.min(viewportHeight,Math.ceil(bottom));
const region = {x:left,y:top,width:right-left,height:bottom-top};
// timeOrigin belongs to the document even if the backend recreates the isolated world.
return JSON.stringify({region, rect:r, document:performance.timeOrigin,
    viewport:{width:innerWidth,height:innerHeight}, scroll:{x:scrollX,y:scrollY}});
