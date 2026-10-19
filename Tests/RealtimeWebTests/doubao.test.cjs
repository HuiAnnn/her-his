const {test} = require('node:test');
const assert = require('node:assert/strict');
const {PCMCollector} = require('../../Sources/CompanionApp/Resources/doubao.js');
test('20ms PCM16 frames preserve streaming samples across irregular blocks',()=>{
  for(const rate of [44100,48000]) {
    const frames=[]; const collector=new PCMCollector(rate,b=>frames.push(b));
    for(let i=0;i<rate;i+=127) collector.push(new Float32Array(Math.min(127,rate-i)).fill(.5));
    assert.equal(frames.length,50);
    for(const b of frames) { assert.equal(b.byteLength,640); assert.equal(new DataView(b).getInt16(0,true),16384); }
  }
});
test('samples clip to signed little endian without wrapping',()=>{
  const frames=[]; const c=new PCMCollector(16000,b=>frames.push(b));
  c.push(new Float32Array(320).fill(-2)); c.push(new Float32Array(320).fill(2));
  assert.equal(new DataView(frames[0]).getInt16(0,true),-32768);
  assert.equal(new DataView(frames[1]).getInt16(0,true),32767);
});
const fs=require('node:fs'), vm=require('node:vm');
function setupMedia(){
  const messages=[],contexts=[],worklets=[],tracks=[{stop(){this.stopped=true;}}];let resolve;
  const connectable=()=>({connect(){},disconnect(){}});
  class Context {
    constructor(){contexts.push(this);this.currentTime=0;this.audioWorklet={addModule:async()=>{}};this.destination={};this.sources=[];}
    createMediaStreamSource(){return connectable();} createGain(){return {...connectable(),gain:{value:0}};}
    createBuffer(_,n,rate){return {duration:n/rate,getChannelData:()=>new Float32Array(n)};}
    createBufferSource(){const source={...connectable(),start(t){this.started=t;},stop(){this.stopped=true;}};this.sources.push(source);return source;}
    async resume(){} async close(){this.closed=true;}
  }
  class Worklet{constructor(){worklets.push(this);this.port={};}connect(){}disconnect(){}}
  const context={window:{webkit:{messageHandlers:{doubao:{postMessage:x=>messages.push(x)}}}},navigator:{mediaDevices:{getUserMedia:()=>new Promise(r=>resolve=r)}},AudioContext:Context,AudioWorkletNode:Worklet,Blob,URL,btoa,atob};
  vm.runInNewContext(fs.readFileSync('Sources/CompanionApp/Resources/doubao.js','utf8'),context);
  return {api:context.window.doubao,messages,contexts,worklets,tracks,resolve:()=>resolve({getTracks:()=>tracks})};
}
test('Doubao late permission resolution releases tracks without opening audio',async()=>{
  const x=setupMedia(),p=x.api.start();x.api.stop();x.resolve();assert.equal(await p,false);assert.equal(x.tracks[0].stopped,true);assert.equal(x.contexts.length,0);
});
test('capture waits for service readiness and bounded backpressure closes media',async()=>{
  const x=setupMedia(),p=x.api.start();x.resolve();await p;const send=x.worklets[0].port.onmessage;
  send({data:new ArrayBuffer(640)});assert.equal(x.messages.length,0);
  x.api.activate();for(let i=0;i<101;i++)send({data:new ArrayBuffer(640)});
  assert.equal(x.messages.at(-1).kind,'failure');assert.equal(x.tracks[0].stopped,true);assert.equal(x.contexts[0].closed,true);
});
test('playback completion waits for actual drain; interrupt returns played duration and cancels late drain',async()=>{
  const x=setupMedia(),p=x.api.start();x.resolve();await p;
  const audio=Buffer.alloc(48000).toString('base64');x.api.play(audio,'r1');x.api.end('r1');
  assert.equal(x.messages.length,0);
  const c=x.contexts[0];c.currentTime=.515;
  const result=x.api.interrupt();assert.equal(result.id,'r1');assert.equal(result.ms,500);
  assert.equal(c.sources[0].stopped,true);assert.equal(c.sources[0].onended,null);
  x.api.play(audio,'r2');x.api.end('r2');c.sources[1].onended();
  assert.equal(x.messages.at(-1).kind,'played');assert.equal(x.messages.at(-1).id,'r2');
  x.api.stop();assert.equal(c.closed,true);
});
test('interrupt between sentence start and first PCM truncates the known reply to zero',async()=>{
  const x=setupMedia(),p=x.api.start();x.resolve();await p;
  x.api.begin('r0');const result=x.api.interrupt();assert.equal(result.id,'r0');assert.equal(result.ms,0);x.api.stop();
});
