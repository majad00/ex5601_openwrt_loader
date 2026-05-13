'use strict';'require baseclass';'require request';let rpcRequestID=1;let rpcSessionID=L.env.sessionid??'00000000000000000000000000000000';let rpcBaseURL=L.url('admin/ubus');const rpcInterceptorFns=[];return baseclass.extend({call(req,cb,nobatch){let q='';if(Array.isArray(req)){if(req.length==0)
return Promise.resolve([]);for(let i=0;i<req.length;i++)
if(req[i].params)
q+='%s%s.%s'.format(q?';':'/',req[i].params[1],req[i].params[2]);}
return request.post(rpcBaseURL+q,req,{timeout:(L.env.rpctimeout??20)*1000,nobatch,credentials:true}).then(cb,cb);},parseCallReply(req,res){let msg=null;if(res instanceof Error)
return req.reject(res);try{if(!res.ok)
L.raise('RPCError','RPC call to %s/%s failed with HTTP error %d: %s',req.object,req.method,res.status,res.statusText||'?');msg=res.json();}
catch(e){return req.reject(e);}
Promise.all(rpcInterceptorFns.map(fn=>fn(msg,req))).then(this.handleCallReply.bind(this,req,msg)).catch(req.reject);},handleCallReply(req,msg){const type=Object.prototype.toString;let ret=null;try{if(!L.isObject(msg)||msg.jsonrpc!='2.0')
L.raise('RPCError','RPC call to %s/%s returned invalid message frame',req.object,req.method);if(L.isObject(msg.error)&&msg.error.code&&msg.error.message)
L.raise('RPCError','RPC call to %s/%s failed with error %d: %s',req.object,req.method,msg.error.code,msg.error.message||'?');}
catch(e){return req.reject(e);}
if(!req.object&&!req.method){ret=msg.result;}
else if(Array.isArray(msg.result)){if(req.raise&&msg.result[0]!==0)
L.raise('RPCError','RPC call to %s/%s failed with ubus code %d: %s',req.object,req.method,msg.result[0],this.getStatusText(msg.result[0]));ret=(msg.result.length>1)?msg.result[1]:msg.result[0];}
if(req.expect){for(const key in req.expect){if(ret!=null&&key!='')
ret=ret[key];if(ret==null||type.call(ret)!=type.call(req.expect[key]))
ret=req.expect[key];break;}}
if(typeof(req.filter)=='function'){req.priv[0]=ret;req.priv[1]=req.params;ret=req.filter.apply(this,req.priv);}
req.resolve(ret);},list(...args){const msg={jsonrpc:'2.0',id:rpcRequestID++,method:'list',params:args.length?args:undefined};return new Promise(L.bind(function(resolve,reject){const req={resolve,reject};this.call(msg,this.parseCallReply.bind(this,req));},this));},declare(options){return Function.prototype.bind.call(function(rpc,options,...args){return new Promise((resolve,reject)=>{let p_off=0;const params={};if(Array.isArray(options.params))
for(p_off=0;p_off<options.params.length;p_off++)
params[options.params[p_off]]=args[p_off];const priv=[undefined,undefined];for(;p_off<args.length;p_off++)
priv.push(args[p_off]);const req={expect:options.expect,filter:options.filter,resolve,reject,params,priv,object:options.object,method:options.method,raise:options.reject};const msg={jsonrpc:'2.0',id:rpcRequestID++,method:'call',params:[rpcSessionID,options.object,options.method,params]};rpc.call(msg,rpc.parseCallReply.bind(rpc,req),options.nobatch);});},this,this,options);},getSessionID(){return rpcSessionID;},setSessionID(sid){rpcSessionID=sid;},getBaseURL(){return rpcBaseURL;},setBaseURL(url){rpcBaseURL=url;},getStatusText(statusCode){switch(statusCode){case 0:return _('Command OK');case 1:return _('Invalid command');case 2:return _('Invalid argument');case 3:return _('Method not found');case 4:return _('Resource not found');case 5:return _('No data received');case 6:return _('Permission denied');case 7:return _('Request timeout');case 8:return _('Not supported');case 9:return _('Unspecified error');case 10:return _('Connection lost');default:return _('Unknown error code');}},addInterceptor(interceptorFn){if(typeof(interceptorFn)=='function')
rpcInterceptorFns.push(interceptorFn);return interceptorFn;},removeInterceptor(interceptorFn){const oldlen=rpcInterceptorFns.length;let i=oldlen;while(i--)
if(rpcInterceptorFns[i]===interceptorFn)
rpcInterceptorFns.splice(i,1);return(rpcInterceptorFns.length<oldlen);}});