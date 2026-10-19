// Only bundled code runs in this view. Credentials never cross the native bridge.
(() => {
  let generation = 0, peer = null, channel = null, stream = null, audio = null;
  let activeResponse = false, outputActive = false, responseRequested = false, interrupted = false;
  const post = (kind, data = {}) => window.webkit.messageHandlers.realtime.postMessage({kind, ...data});
  function stop() {
    ++generation;
    const oldStream = stream, oldPeer = peer, oldChannel = channel, oldAudio = audio;
    stream = peer = channel = audio = null; activeResponse = outputActive = responseRequested = interrupted = false;
    if (oldStream) oldStream.getTracks().forEach(t => t.stop());
    if (oldChannel) oldChannel.close();
    if (oldPeer) oldPeer.close();
    if (oldAudio) { oldAudio.muted = true; oldAudio.pause(); oldAudio.srcObject = null; oldAudio.remove(); }
  }
  function send(event) {
    if (!channel || channel.readyState !== 'open') throw new Error('channel unavailable');
    if (event.type === 'conversation.item.create' && event.item?.role === 'user') interrupted = false;
    if (event.type === 'response.create') responseRequested = true;
    channel.send(JSON.stringify(event));
  }
  function interrupt() {
    interrupted = true;
    if (audio) audio.muted = true;
    const shouldClear = outputActive || activeResponse;
    if (activeResponse || responseRequested) { send({type:'response.cancel'}); activeResponse=false; responseRequested=false; }
    if (shouldClear) send({type:'output_audio_buffer.clear'});
  }
  async function start() {
    stop(); const token = generation;
    const media = await navigator.mediaDevices.getUserMedia({video:false,audio:{echoCancellation:true,noiseSuppression:true,autoGainControl:true}});
    if (token !== generation) { media.getTracks().forEach(t=>t.stop()); throw new Error('cancelled'); }
    stream = media;
    const pc = new RTCPeerConnection(); peer = pc;
    const current = () => token === generation && peer === pc;
    audio = document.createElement('audio'); audio.autoplay = true;
    document.body.appendChild(audio);
    pc.ontrack = event => {
      if (!current()) return;
      audio.srcObject = event.streams[0];
      audio.play().catch(() => { if (current()) post('failure',{code:'playback'}); });
    };
    for (const track of media.getAudioTracks()) {
      track.onended = () => { if (current()) post('failure',{code:'microphone'}); };
      pc.addTrack(track, media);
    }
    pc.onconnectionstatechange = () => {
      if (current() && ['failed','disconnected','closed'].includes(pc.connectionState)) post('failure',{code:'connection'});
    };
    const dc = pc.createDataChannel('oai-events'); channel = dc;
    dc.onopen = () => { if (current()) post('ready'); };
    dc.onclose = () => { if (current()) post('failure',{code:'connection'}); };
    dc.onerror = () => { if (current()) post('failure',{code:'connection'}); };
    dc.onmessage = message => {
      if (!current() || typeof message.data !== 'string' || message.data.length > 262144) return;
      let event; try { event = JSON.parse(message.data); } catch { post('failure',{code:'protocol'}); return; }
      if (event.type === 'response.created') {
        responseRequested=false;
        if (interrupted) {
          audio.muted=true; activeResponse=false;
          send({type:'response.cancel',response_id:event.response.id});
        } else { activeResponse=true; audio.muted=false; }
      }
      if (event.type === 'response.done') activeResponse=false;
      if (event.type === 'output_audio_buffer.started') outputActive=true;
      if (['output_audio_buffer.stopped','output_audio_buffer.cleared'].includes(event.type)) outputActive=false;
      if (event.type === 'input_audio_buffer.speech_started') { audio.muted=true; activeResponse=false; responseRequested=false; interrupted=false; }
      if (event.type === 'input_audio_buffer.speech_stopped') responseRequested=true;
      post('event',{event});
    };
    const offer = await pc.createOffer();
    if (!current()) throw new Error('cancelled');
    await pc.setLocalDescription(offer);
    if (!current()) throw new Error('cancelled');
    return offer.sdp;
  }
  async function answer(sdp) {
    const pc=peer, token=generation;
    if (!pc) throw new Error('cancelled');
    await pc.setRemoteDescription({type:'answer',sdp});
    if (token!==generation || peer!==pc) throw new Error('cancelled');
  }
  window.presence = {start, answer, send, interrupt, stop};
})();
