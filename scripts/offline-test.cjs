// Optional offline tests: Node.js + pwsh. Never connects to a real browser.
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const vm = require('node:vm');
const {execFile} = require('node:child_process');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
function frame(bytes, opcode, fin) {
  const header = bytes.length < 126 ? Buffer.from([(fin ? 128 : 0) | opcode, bytes.length]) : Buffer.alloc(4);
  if (bytes.length >= 126) { header[0] = (fin ? 128 : 0) | opcode; header[1] = 126; header.writeUInt16BE(bytes.length, 2); }
  return Buffer.concat([header, bytes]);
}
function runPs(command) {
  const encoded = Buffer.from(command, 'utf16le').toString('base64');
  return new Promise(resolve => execFile('pwsh', ['-NoProfile','-EncodedCommand',encoded], {encoding:'utf8',maxBuffer:2e6}, (error,stdout,stderr)=>resolve({error,stdout,stderr})));
}
async function testCdp() {
  let port;
  let connections = 0;
  const unicode = '中文课程✓' + '汉'.repeat(30000);
  const sockets = new Set();
  const server = http.createServer((req,res)=> {
    res.setHeader('content-type','application/json; charset=utf-8');
    res.end(JSON.stringify(['a','b'].map(id=>({id,type:'page',url:'https://example.test/duplicate',title:'模拟课程',webSocketDebuggerUrl:`ws://127.0.0.1:${port}/cdp/${id}`}))));
  });
  server.on('connection', socket=>{sockets.add(socket);socket.on('close',()=>sockets.delete(socket));});
  server.on('upgrade',(req,socket)=> {
    connections++;
    const accept = crypto.createHash('sha1').update(req.headers['sec-websocket-key']+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    let pending=Buffer.alloc(0), handled=false;
    socket.on('data',chunk=> {
      pending=Buffer.concat([pending,chunk]);
      if(handled||pending.length<6)return;
      let length=pending[1]&127, offset=2;
      if(length===126){if(pending.length<8)return;length=pending.readUInt16BE(2);offset=4;}
      if(length===127)throw Error('Unexpected large request');
      if(pending.length<offset+4+length)return;
      handled=true;
      const mask=pending.subarray(offset,offset+4),data=Buffer.from(pending.subarray(offset+4,offset+4+length));
      for(let i=0;i<data.length;i++)data[i]^=mask[i%4];
      const message=JSON.parse(data.toString('utf8'));
      const result=message.method==='Runtime.evaluate'?{result:{type:'string',value:unicode}}:{selectedTarget:req.url.split('/').pop()};
      const bytes=Buffer.from(JSON.stringify({id:message.id,result}));
      // Split inside UTF-8 data and exceed the client's receive buffer in total.
      socket.write(frame(bytes.subarray(0,30001),1,false));
      socket.write(frame(bytes.subarray(30001,60002),0,false));
      socket.write(frame(bytes.subarray(60002),0,true));
    });
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  port=server.address().port;
  const client=path.join(root,'scripts','cdp.ps1').replace(/'/g,"''");
  const prefix=`$ErrorActionPreference='Stop'; $client=[scriptblock]::Create([IO.File]::ReadAllText('${client}')); & $client -Port ${port} `;
  try {
    const ambiguous=await runPs(prefix+"-UrlLike 'duplicate' -Expression 'document.title'");
    assert(ambiguous.error,'Duplicate selection must fail');
    assert.equal(connections,0,'Ambiguous target must never open a WebSocket');
    const exact=await runPs(prefix+"-TargetId 'a' -Expression 'document.title'");
    assert.ifError(exact.error);
    assert.equal(exact.stdout.trimEnd(),unicode,'UTF-8 must survive message and buffer fragmentation');
    const other=await runPs(prefix+"-TargetId 'b' -CdpMethod 'Test.echo' -Expression '1'");
    assert.ifError(other.error);
    assert.equal(JSON.parse(other.stdout).selectedTarget,'b');
    console.log('PASS: ambiguous target refusal, exact target routing, fragmented Chinese WebSocket output');
  } finally { for(const socket of sockets)socket.destroy(); await new Promise(resolve=>server.close(resolve)); }
}
async function testAutoplay() {
  const script=fs.readFileSync(path.join(root,'scripts','autoplay.ps1'),'utf8');
  const match=script.match(/\$expression = @'\r?\n([\s\S]*?)\r?\n'@/);
  assert(match,'Autoplay expression missing');
  const expression=match[1].replaceAll('__COURSE_ID__','12345');
  for(const mode of ['new','spa','pause','next','complete','error','wrong']) {
    let plays=0,clicks=0;
    const current={querySelector:()=>({innerText:'current'})};
    const next={querySelector:()=>({innerText:'next'}),click:()=>clicks++};
    const video={readyState:4,paused:true,ended:['next','complete'].includes(mode),currentTime:10,duration:20,error:mode==='error'?{code:3}:null,play:async()=>{plays++;video.paused=false;}};
    const context={URLSearchParams,location:{search:`?courseId=${mode==='wrong'?'999':'12345'}&fileId=1`},window:['pause','spa'].includes(mode)?{__zhihuishuAutoplay:{started:true,fileId:mode==='spa'?'0':'1'}}:{},setTimeout:callback=>callback(),document:{querySelector:selector=>selector==='video'?video:current,querySelectorAll:()=>mode==='complete'?[current]:[current,next]}};
    const state=JSON.parse(await vm.runInNewContext(expression,context,{timeout:1000}));
    const expected={new:'playing',spa:'playing',pause:'paused',next:'next',complete:'complete',error:'video-error',wrong:'other-course'}[mode];
    assert.equal(state.status,expected,mode);
    assert.equal(plays,['new','spa'].includes(mode)?1:0,mode+' play calls');
    assert.equal(clicks,mode==='next'?1:0,mode+' next calls');
  }
  console.log('PASS: first playback, SPA video change, manual pause, natural end, final video, video error, course mismatch');
}
(async()=>{await testCdp();await testAutoplay();})().catch(error=>{console.error(error);process.exitCode=1;});
