// Browser selector for actual Flutter accessible labels and readonly values.
module.exports = () => {
  const matches = (root, selector) => {
   const {text,prefix=false,line=false}=JSON.parse(selector);
   const nodes=[];const collect=scope=>{nodes.push(...scope.querySelectorAll('flt-semantics,[aria-label],[aria-valuetext],input,textarea'));for(const el of scope.querySelectorAll('*'))if(el.shadowRoot)collect(el.shadowRoot);};collect(root);
   const found=nodes.filter(el=>[el.getAttribute('aria-label'),el.getAttribute('aria-valuetext'),('value' in el ? el.value : null),el.textContent].some(v=>typeof v==='string'&&(line?v.split(/\r?\n/).some(part=>part.trim()===text):prefix?v.startsWith(text):v===text)));
   return found.filter(el=>!found.some(other=>other!==el&&el.contains(other)));
  };
  return {query:(root,selector)=>matches(root,selector)[0]||null,queryAll:matches};
 };
