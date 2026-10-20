/* Media only. Credentials and WebSocket never enter this isolated document. */
class PCMCollector {
  constructor(rate, emit) { this.ratio=rate/16000; this.emit=emit; this.remaining=this.ratio; this.sum=0; this.samples=[]; }
  push(input) {
    for (const sample of input) {
      let left=1;
      while(left>1e-8) {
        const weight=Math.min(left,this.remaining);
        this.sum+=Math.max(-1,Math.min(1,sample))*weight;
        this.remaining-=weight; left-=weight;
        if(this.remaining<1e-8) {
          const value=this.sum/this.ratio;
          this.samples.push(Math.round(value*(value<0?32768:32767)));
          this.remaining=this.ratio; this.sum=0;
          if(this.samples.length===320) {
            const b=new ArrayBuffer(640), v=new DataView(b);
            this.samples.forEach((x,i)=>v.setInt16(i*2,x,true));
            this.samples=[]; this.emit(b);
          }
        }
      }
    }
  }
}
if(typeof module!=='undefined') module.exports={PCMCollector};
if(typeof window!=='undefined') (()=>{
  let epoch=0, stream=null, ctx=null, mic=null, node=null, sink=null, upload=false, pending=0;
  let nodes=[], nextTime=0, response=null, ended=false, played=0, draining=false;
  const post=(kind,extra={})=>window.webkit.messageHandlers.doubao.postMessage({kind,...extra});
  const encode=b=>btoa(String.fromCharCode(...new Uint8Array(b)));
  function clear() {
    const now=ctx?.currentTime||0;
    let ms=played;
    for(const entry of nodes) { ms+=Math.max(0,Math.min(entry.duration,now-entry.start))*1000; entry.source.onended=null; try{entry.source.stop();}catch{} entry.source.disconnect(); }
    const result={id:response||'',ms:Math.floor(ms)};
    nodes=[]; nextTime=now; response=null; ended=false; played=0; draining=false;
    return result;
  }
  function stop() {
    ++epoch; upload=false; pending=0; clear();
    stream?.getTracks().forEach(t=>{t.onended=null;t.stop();}); stream=null;
    if(node) {node.port.onmessage=null; node.disconnect(); node=null;}
    mic?.disconnect(); mic=null; sink?.disconnect(); sink=null;
    if(ctx){const old=ctx;ctx=null;old.onstatechange=null;old.close().catch(()=>{});}
  }
  function finish() {
    if(ended&&!nodes.length&&response&&!draining){draining=true;post('played',{id:response});}
  }
  window.doubao={
    async start() {
      stop(); const token=epoch;
      const media=await navigator.mediaDevices.getUserMedia({audio:{channelCount:1,echoCancellation:true,noiseSuppression:true,autoGainControl:true}});
      if(token!==epoch){media.getTracks().forEach(t=>t.stop());return false;} stream=media;
      ctx=new AudioContext(); const audio=ctx;
      const source=`${PCMCollector.toString()}\nclass Capture extends AudioWorkletProcessor { constructor(){super();this.collector=new PCMCollector(sampleRate,b=>this.port.postMessage(b,[b]));} process(inputs){if(inputs[0]?.[0])this.collector.push(inputs[0][0]);return true;} } registerProcessor('capture',Capture);`;
      const url=URL.createObjectURL(new Blob([source],{type:'text/javascript'}));
      try {await audio.audioWorklet.addModule(url);} finally {URL.revokeObjectURL(url);}
      if(token!==epoch)return false;
      mic=audio.createMediaStreamSource(media); node=new AudioWorkletNode(audio,'capture');
      sink=audio.createGain(); sink.gain.value=0; mic.connect(node);node.connect(sink);sink.connect(audio.destination);
      node.port.onmessage=({data})=>{
        if(token!==epoch||!upload)return;
        if(++pending>100){stop();post('failure');return;}
        post('audio',{data:encode(data)});
      };
      media.getTracks().forEach(track=>{track.onended=()=>{if(token===epoch){stop();post('failure');}};});
      await audio.resume();
      if(token!==epoch)return false;
      // An interrupted context can resolve resume() without actually running.
      // End this call rather than leaving capture and a silent connection alive.
      audio.onstatechange=()=>{
        if(token===epoch&&ctx===audio&&audio.state!=='running'){
          stop();post('failure',{code:'audio_interrupted'});
        }
      };
      audio.onstatechange();
      return token===epoch;
    },
    activate(){upload=true;}, ack(){pending=Math.max(0,pending-1);},
    begin(id){if(response!==id){clear();response=id;}},
    play(base64,id) {
      if(!ctx)return;
      if(response!==id){clear();response=id;}
      const binary=atob(base64); if(binary.length%2)throw Error('bad pcm');
      const bytes=Uint8Array.from(binary,c=>c.charCodeAt(0)),view=new DataView(bytes.buffer);
      const buffer=ctx.createBuffer(1,bytes.length/2,24000),channel=buffer.getChannelData(0);
      for(let i=0;i<channel.length;i++)channel[i]=view.getInt16(i*2,true)/32768;
      const start=Math.max(ctx.currentTime+.015,nextTime);
      if(start-ctx.currentTime>30){stop();post('failure');return;}
      const source=ctx.createBufferSource();source.buffer=buffer;source.connect(ctx.destination);
      const entry={source,start,duration:buffer.duration};nodes.push(entry);nextTime=start+buffer.duration;
      source.onended=()=>{const i=nodes.indexOf(entry);if(i<0)return;nodes.splice(i,1);played+=buffer.duration*1000;source.disconnect();finish();};
      source.start(start);
    },
    end(id){if(response===id){ended=true;finish();}}, interrupt:clear, stop
  };
})();
