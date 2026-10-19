const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
function setup() {
  const tracks = [{stopped: false, stop() { this.stopped = true; }}];
  const messages = [], sent = [], peers = [];
  let resolveMedia;
  const audio = {autoplay: false, muted: false, srcObject: null, play: async () => {}, pause() {}, remove() {}};
  class Peer {
    constructor() { peers.push(this); this.connectionState = 'new'; }
    addTrack() {}
    createDataChannel() { this.dc = {readyState: 'open', send: x => sent.push(JSON.parse(x)), close() {this.readyState='closed';}}; return this.dc; }
    async createOffer() { return {sdp:'v=0\r\noffer', type:'offer'}; }
    async setLocalDescription(x) { this.localDescription=x; }
    async setRemoteDescription(x) { this.remoteDescription=x; }
    close() {this.closed=true;}
  }
  const ctx = {window: {webkit: {messageHandlers: {realtime: {postMessage: x => messages.push(x)}}}}, navigator: {mediaDevices: {getUserMedia: () => new Promise(r => resolveMedia=r)}}, document: {createElement:()=>audio,body:{appendChild(){}}}, RTCPeerConnection:Peer, setTimeout, clearTimeout, JSON};
  vm.runInNewContext(fs.readFileSync('Sources/CompanionApp/Resources/realtime.js','utf8'),ctx);
  return {api:ctx.window.presence, resolve:()=>resolveMedia({getTracks:()=>tracks,getAudioTracks:()=>tracks}), tracks,messages,sent,peers,audio};
}
test('stop releases capture even when permission resolves late',async()=>{
  const x=setup(); const starting=x.api.start(); x.api.stop(); x.resolve();
  await assert.rejects(starting); assert.equal(x.tracks[0].stopped,true); assert.equal(x.peers.length,0);
});
test('stop closes peer and rejects a late answer',async()=>{
  const x=setup(); const starting=x.api.start(); x.resolve(); await starting;
  x.api.stop(); await assert.rejects(x.api.answer('v=0\r\nanswer'));
  assert.equal(x.tracks[0].stopped,true); assert.equal(x.peers[0].closed,true); assert.equal(x.audio.srcObject,null);
});
test('manual interrupt immediately silences playback and clears remote audio',async()=>{
  const x=setup(); const starting=x.api.start(); x.resolve(); await starting;
  x.peers[0].dc.onmessage({data:JSON.stringify({type:'response.created',response:{id:'r1'}})});
  x.api.interrupt(); assert.equal(x.audio.muted,true);
  assert.deepEqual(x.sent.map(x=>x.type),['response.cancel','output_audio_buffer.clear']);
  x.peers[0].dc.onmessage({data:JSON.stringify({type:'input_audio_buffer.speech_started'})});
  x.peers[0].dc.onmessage({data:JSON.stringify({type:'response.created',response:{id:'r2'}})});
  assert.equal(x.audio.muted,false); x.api.stop();
});
test('interrupting before the first response sends no invalid buffer commands',async()=>{
  const x=setup(); const starting=x.api.start(); x.resolve(); await starting;
  x.api.interrupt(); assert.equal(x.sent.length,0); x.api.stop();
});
test('manual stop stays muted when response creation arrives late',async()=>{
  const x=setup(); const starting=x.api.start(); x.resolve(); await starting;
  x.api.send({type:'response.create'}); x.api.interrupt();
  x.peers[0].dc.onmessage({data:JSON.stringify({type:'response.created',response:{id:'late'}})});
  assert.equal(x.audio.muted,true);
  assert.ok(x.sent.some(e=>e.type==='response.cancel'));
  x.api.stop();
});
