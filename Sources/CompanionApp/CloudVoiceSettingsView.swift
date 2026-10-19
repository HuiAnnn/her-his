import SwiftUI
import CompanionCore

struct CloudVoiceSettingsView: View {
    @ObservedObject var output: CloudVoiceOutput
    @ObservedObject var controller: CompanionController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("使用云端声音 · ElevenLabs", isOn: Binding(
                get: { output.enabled },
                set: { controller.interrupt(); output.enabled = $0 }
            )).disabled(output.voiceID.isEmpty)
            Text("开启后，将待朗读的回复文字发送给 ElevenLabs。回复可能包含你刚聊过的内容；服务商的数据保留以账户设置和条款为准。麦克风录音、完整对话和记忆文件不会作为请求上传。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("ElevenLabs API Key").font(.system(size: 12, weight: .medium))
                Spacer()
                Link(destination: URL(string: "https://elevenlabs.io/app/settings/api-keys")!) {
                    Label("去官网获取 API Key", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .help("在浏览器打开 ElevenLabs 官方 API Key 页面")
            }
            Text("还没有 Key？点击上方按钮，在官网登录或注册后创建，再复制回来粘贴。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                SecureField("ElevenLabs API Key（保存后隐藏）", text: $output.keyDraft)
                    .textFieldStyle(.roundedBorder)
                Button("保存密钥") { output.saveKey() }.disabled(output.keyDraft.isEmpty)
            }
            HStack {
                Spacer()
                Button("移除密钥") { output.removeKey() }
            }.font(.system(size: 11))
            Text("密钥只存入 macOS 钥匙串，不写进项目或聊天。Key 需允许语音合成、读取声线与模型。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            HStack {
                Button(output.loading ? "读取中…" : "读取声线与模型") { output.loadCatalog() }.disabled(output.loading)
                Link("打开声音库", destination: URL(string: "https://elevenlabs.io/app/voice-library")!)
                    .font(.system(size: 11))
            }
            if !output.voices.isEmpty {
                Picker("声线", selection: $output.voiceID) {
                    Text("请选择，试听后再决定").tag("")
                    if !output.voiceID.isEmpty, !output.voices.contains(where: { $0.id == output.voiceID }) {
                        Text("已保存：\(output.voiceID)").tag(output.voiceID)
                    }
                    ForEach(output.voices) { voice in Text(voice.name).tag(voice.id) }
                }
            } else {
                TextField("Voice ID（可从声音库复制，或读取声线后选择）", text: $output.voiceID)
                    .textFieldStyle(.roundedBorder)
            }
            Picker("语音模型", selection: $output.modelID) {
                if !output.models.contains(where: { $0.id == output.modelID }) {
                    Text(output.modelID == "eleven_v3" ? "Eleven v3 · 待连接验证" : output.modelID).tag(output.modelID)
                }
                ForEach(output.models) { item in Text(item.name ?? item.id).tag(item.id) }
            }
            Text("读取后显示服务商提供的中文语音模型；账户是否有使用权限，以实际试听结果为准。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Text("“\(CloudVoiceOutput.previewText)”")
                .font(.system(size: 12)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("试听这句话") { controller.previewVoice() }
                    .disabled(output.isBusy || output.voiceID.isEmpty || output.loading)
                if output.isBusy { Button("停止播放") { output.stop() } }
                Text("试听会使用账户额度，并暂停麦克风。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(output.message).font(.system(size: 11)).foregroundStyle(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: output.voiceID) { _, _ in controller.interrupt() }
        .onChange(of: output.modelID) { _, _ in controller.interrupt() }
        .onDisappear { output.keyDraft = ""; output.stop() }
    }
}
