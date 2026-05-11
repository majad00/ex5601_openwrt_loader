'use strict';'require rpc';'require baseclass';function isEmpty(object,ignore){for(const property in object)
if(object.hasOwnProperty(property)&&property!=ignore)
return false;return true;}
return baseclass.extend({__init__(){this.state={newidx:0,values:{},creates:{},changes:{},deletes:{},reorder:{}};this.loaded={};},callLoad:rpc.declare({object:'uci',method:'get',params:['config'],expect:{values:{}},reject:true}),callOrder:rpc.declare({object:'uci',method:'order',params:['config','sections'],reject:true}),callAdd:rpc.declare({object:'uci',method:'add',params:['config','type','name','values'],expect:{section:''},reject:true}),callSet:rpc.declare({object:'uci',method:'set',params:['config','section','values'],reject:true}),callDelete:rpc.declare({object:'uci',method:'delete',params:['config','section','options'],reject:true}),callApply:rpc.declare({object:'uci',method:'apply',params:['timeout','rollback'],reject:true}),callConfirm:rpc.declare({object:'uci',method:'confirm',reject:true}),createSID(conf){const v=this.state.values;const n=this.state.creates;let sid;do{sid="new%06x".format(Math.random()*0xFFFFFF);}while((n[conf]?.[sid])||(v[conf]?.[sid]));return sid;},resolveSID(conf,sid){if(typeof(sid)!='string')
return sid;const m=/^@([a-zA-Z0-9_-]+)\[(-?[0-9]+)\]$/.exec(sid);if(m){const type=m[1];const pos=+m[2];const sections=this.sections(conf,type);const section=sections[pos>=0?pos:sections.length+pos];return section?.['.name']??null;}
return sid;},reorderSections(){const v=this.state.values;const n=this.state.creates;const d=this.state.deletes;const r=this.state.reorder;const tasks=[];if(Object.keys(r).length===0)
return Promise.resolve();for(const c in r){const o=[];if(d[c])
continue;if(n[c])
for(const s in n[c])
o.push(n[c][s]);for(const s in v[c])
o.push(v[c][s]);if(o.length>0){o.sort((a,b)=>a['.index']-b['.index']);const sids=[];for(let i=0;i<o.length;i++)
sids.push(o[i]['.name']);tasks.push(this.callOrder(c,sids));}}
this.state.reorder={};return Promise.all(tasks);},loadPackage(packageName){if(this.loaded[packageName]==null)
return(this.loaded[packageName]=this.callLoad(packageName));return Promise.resolve(this.loaded[packageName]);},load(packages){const self=this;const pkgs=[];const tasks=[];if(!Array.isArray(packages))
packages=[packages];for(let i=0;i<packages.length;i++)
if(!self.state.values[packages[i]]){pkgs.push(packages[i]);tasks.push(self.loadPackage(packages[i]));}
return Promise.all(tasks).then(responses=>{for(let i=0;i<responses.length;i++)
self.state.values[pkgs[i]]=responses[i];if(responses.length)
document.dispatchEvent(new CustomEvent('uci-loaded'));return pkgs;});},unload(packages){if(!Array.isArray(packages))
packages=[packages];for(let i=0;i<packages.length;i++){delete this.state.values[packages[i]];delete this.state.creates[packages[i]];delete this.state.changes[packages[i]];delete this.state.deletes[packages[i]];delete this.loaded[packages[i]];}},add(conf,type,name){const n=this.state.creates;const sid=name||this.createSID(conf);n[conf]??={};n[conf][sid]={'.type':type,'.name':sid,'.create':name,'.anonymous':!name,'.index':1000+this.state.newidx++};return sid;},clone(conf,type,srcsid,put_next,name){let n=this.state.creates;let sid=this.createSID(conf);let v=this.state.values;put_next=put_next||false;if(!n[conf])
n[conf]={};n[conf][sid]={...v[conf][srcsid],'.type':type,'.name':sid,'.create':name,'.anonymous':!name,'.index':1000+this.state.newidx++};if(put_next)
this.move(conf,sid,srcsid,put_next);return sid;},remove(conf,sid){const v=this.state.values;const n=this.state.creates;const c=this.state.changes;const d=this.state.deletes;if(n[conf]?.[sid]){delete n[conf][sid];}
else if(v[conf]?.[sid]){delete c[conf]?.[sid];d[conf]??={};d[conf][sid]=true;}},sections(conf,type,cb){const sa=[];const v=this.state.values[conf];const n=this.state.creates[conf];const c=this.state.changes[conf];const d=this.state.deletes[conf];if(!v)
return sa;for(const s in v)
if(!d||d[s]!==true)
if(!type||v[s]['.type']==type)
sa.push(Object.assign({},v[s],c?c[s]:null));if(n)
for(const s in n)
if(!type||n[s]['.type']==type)
sa.push(Object.assign({},n[s]));sa.sort((a,b)=>{return a['.index']-b['.index'];});for(let i=0;i<sa.length;i++)
sa[i]['.index']=i;if(typeof(cb)=='function')
for(let i=0;i<sa.length;i++)
cb.call(this,sa[i],sa[i]['.name']);return sa;},get(conf,sid,opt){const v=this.state.values;const n=this.state.creates;const c=this.state.changes;const d=this.state.deletes;sid=this.resolveSID(conf,sid);if(sid==null)
return null;if(n[conf]?.[sid]){if(opt==null)
return n[conf][sid];return n[conf][sid][opt];}
if(opt!=null){if(d[conf]?.[sid])
if(d[conf][sid]===true||d[conf][sid][opt])
return null;if(c[conf]?.[sid]?.[opt]!=null)
return c[conf][sid][opt];if(v[conf]?.[sid])
return v[conf][sid][opt];return null;}
if(v[conf]){if(d[conf]?.[sid]===true)
return null;const s=v[conf][sid]||null;if(s){if(c[conf]?.[sid])
for(const opt in c[conf][sid])
if(c[conf][sid][opt]!=null)
s[opt]=c[conf][sid][opt];if(d[conf]?.[sid])
for(const opt in d[conf][sid])
delete s[opt];}
return s;}
return null;},set(conf,sid,opt,val){const v=this.state.values;const n=this.state.creates;const c=this.state.changes;const d=this.state.deletes;sid=this.resolveSID(conf,sid);if(sid==null||opt==null||opt.charAt(0)=='.')
return;if(n[conf]?.[sid]){if(val!=null)
n[conf][sid][opt]=val;else
delete n[conf][sid][opt];}
else if(val!=null&&val!==''){if(d[conf]&&d[conf][sid]===true)
return;if(!v[conf]?.[sid])
return;c[conf]??={};c[conf][sid]??={};if(d[conf]?.[sid]){if(isEmpty(d[conf][sid],opt))
delete d[conf][sid];else
delete d[conf][sid][opt];}
c[conf][sid][opt]=val;}
else{if(c[conf]?.[sid]){if(isEmpty(c[conf][sid],opt))
delete c[conf][sid];else
delete c[conf][sid][opt];}
if(v[conf]?.[sid]?.hasOwnProperty(opt)){d[conf]??={};d[conf][sid]??={};if(d[conf][sid]!==true)
d[conf][sid][opt]=true;}}},unset(conf,sid,opt){return this.set(conf,sid,opt,null);},get_first(conf,type,opt){let sid=null;this.sections(conf,type,s=>{sid??=s['.name'];});return this.get(conf,sid,opt);},get_bool(conf,type,opt){let value=this.get(conf,type,opt);if(typeof(value)=='string')
return['1','on','true','yes','enabled'].includes(value.toLowerCase());return false;},set_first(conf,type,opt,val){let sid=null;this.sections(conf,type,s=>{sid??=s['.name'];});return this.set(conf,sid,opt,val);},unset_first(conf,type,opt){return this.set_first(conf,type,opt,null);},move(conf,sid1,sid2,after){const sa=this.sections(conf);let s1=null;let s2=null;sid1=this.resolveSID(conf,sid1);sid2=this.resolveSID(conf,sid2);for(let i=0;i<sa.length;i++){if(sa[i]['.name']!=sid1)
continue;s1=sa[i];sa.splice(i,1);break;}
if(s1==null)
return false;if(sid2==null){sa.push(s1);}
else{for(let i=0;i<sa.length;i++){if(sa[i]['.name']!=sid2)
continue;s2=sa[i];sa.splice(i+!!after,0,s1);break;}
if(s2==null)
return false;}
for(let i=0;i<sa.length;i++)
this.get(conf,sa[i]['.name'])['.index']=i;this.state.reorder[conf]=true;return true;},save(){const v=this.state.values;const n=this.state.creates;const c=this.state.changes;const d=this.state.deletes;const r=this.state.reorder;const self=this;const snew=[];let pkgs={};const tasks=[];if(d)
for(const conf in d){for(const sid in d[conf]){const o=d[conf][sid];if(o===true)
tasks.push(self.callDelete(conf,sid,null));else
tasks.push(self.callDelete(conf,sid,Object.keys(o)));}
pkgs[conf]=true;}
if(n)
for(const conf in n){for(const sid in n[conf]){const p={config:conf,values:{}};for(const k in n[conf][sid]){if(k=='.type')
p.type=n[conf][sid][k];else if(k=='.create')
p.name=n[conf][sid][k];else if(k.charAt(0)!='.')
p.values[k]=n[conf][sid][k];}
snew.push(n[conf][sid]);tasks.push(self.callAdd(p.config,p.type,p.name,p.values));}
pkgs[conf]=true;}
if(c)
for(const conf in c){for(const sid in c[conf])
tasks.push(self.callSet(conf,sid,c[conf][sid]));pkgs[conf]=true;}
if(r)
for(const conf in r)
pkgs[conf]=true;return Promise.all(tasks).then(responses=>{for(let i=0;i<snew.length;i++)
snew[i]['.name']=responses[i];return self.reorderSections();}).then(()=>{pkgs=Object.keys(pkgs);self.unload(pkgs);return self.load(pkgs);});},apply(timeout){const self=this;const date=new Date();if(typeof(timeout)!='number'||timeout<1)
timeout=10;return self.callApply(timeout,true).then(rv=>{if(rv!=0)
return Promise.reject(rv);const try_deadline=date.getTime()+1000*timeout;const try_confirm=()=>{return self.callConfirm().then(rv=>{if(rv!=0){if(date.getTime()<try_deadline)
window.setTimeout(try_confirm,250);else
return Promise.reject(rv);}
return rv;});};window.setTimeout(try_confirm,1000);});},changes:rpc.declare({object:'uci',method:'changes',expect:{changes:{}}})});