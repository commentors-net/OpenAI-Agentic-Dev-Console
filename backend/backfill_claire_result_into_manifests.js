#!/usr/bin/env node
const fs = require("fs");
const path = require("path");
const MANIFEST_ROOT = "/home/servicedepartmen/public_html/dealdesk/source-docs/manifests";
const CACHE_ROOT = "/home/servicedepartmen/dealdesk-backend/cache/claire-dealview";
function readJson(file){ try{return JSON.parse(fs.readFileSync(file,"utf8"));}catch(e){return null;} }
function listJson(dir){ if(!fs.existsSync(dir))return []; return fs.readdirSync(dir).filter(n=>n.toLowerCase().endsWith(".json")).map(n=>path.join(dir,n)); }
const cacheByUid = new Map();
for(const file of listJson(CACHE_ROOT)){
  const data=readJson(file);
  if(data && data.uid && data.result) cacheByUid.set(String(data.uid), {result:data.result, raw_output:data.raw_output||"", cache_file:file});
}
let changed=0, inspected=0;
for(const file of listJson(MANIFEST_ROOT)){
  const m=readJson(file); if(!m)continue; inspected++;
  if(m.claire_result)continue;
  const cached=m.uid ? cacheByUid.get(String(m.uid)) : null;
  if(cached){
    m.claire_result=cached.result;
    m.claire_raw_output=cached.raw_output;
    m.claire_backup_note="Full CLAIRE intake read backfilled from sidecar cache.";
    m.claire_cache_file=cached.cache_file;
    m.updated_at=new Date().toISOString();
    fs.writeFileSync(file, JSON.stringify(m,null,2));
    changed++;
  }
}
console.log(JSON.stringify({ok:true, inspected, changed, cache_entries:cacheByUid.size}, null, 2));
