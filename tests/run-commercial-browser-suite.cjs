// One process owns the local server and all browser tests, including across tool yields.
const http=require('node:http'),fs=require('node:fs'),path=require('node:path'),{spawn}=require('node:child_process');
const root=path.resolve(__dirname,'..');
const tests=['qa-commercial-ui.cjs','qa-v100.cjs','qa-v103-calendar-billing.cjs','qa-v107-beta-final.cjs','qa-v108-voice.cjs','qa-v109-pending-fixes.cjs','qa-managed-students-browser.cjs','qa-diet-variants-browser.cjs'];
const server=http.createServer((req,res)=>{
  const file=path.resolve(root,'.'+new URL(req.url,'http://localhost').pathname);
  if(file!==root && !file.startsWith(root+path.sep)) return res.writeHead(403).end();
  const target=file===root?path.join(root,'index.html'):file;
  const mime=target.endsWith('.html')?'text/html; charset=utf-8':target.endsWith('.js')?'application/javascript':target.endsWith('.svg')?'image/svg+xml':'text/plain';
  fs.readFile(target,(e,bytes)=>e?res.writeHead(404).end():res.writeHead(200,{'Content-Type':mime}).end(bytes));
});
async function main(){
  fs.mkdirSync(path.join(root,'artifacts'),{recursive:true});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  let failed=0;
  try{
    for(const test of tests){
      const log=fs.createWriteStream(path.join(root,'artifacts',test+'.final.log'));
      const status=await new Promise((resolve,reject)=>{
        const child=spawn(process.execPath,[path.join(__dirname,test)],{cwd:root,env:{...process.env,BASE_URL:'http://127.0.0.1:'+server.address().port+'/'}});
        child.stdout.pipe(log,{end:false});child.stderr.pipe(log,{end:false});
        const timer=setTimeout(()=>child.kill(),180000);
        child.on('error',reject);
        child.on('close',code=>{clearTimeout(timer);log.end(()=>resolve(code));});
      });
      console.log(test+': '+status);
      if(status!==0){failed++;console.log(fs.readFileSync(path.join(root,'artifacts',test+'.final.log'),'utf8').slice(-2500));}
    }
  }finally{await new Promise(resolve=>server.close(resolve));}
  if(failed)process.exitCode=1;
}
main().catch(e=>{console.error(e);process.exitCode=1;server.close();});

