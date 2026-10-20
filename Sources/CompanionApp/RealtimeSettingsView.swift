import SwiftUI
import CompanionCore

struct RealtimeSettingsView: View {
    @ObservedObject var realtime: RealtimeConversation
    @ObservedObject var controller: CompanionController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("直接语音对话", isOn: Binding(get: { realtime.enabled }, set: { controller.setRealtimeEnabled($0) }))
            Picker("语音服务", selection: $realtime.provider) {
                Text("豆包 · 中文实时语音").tag(RealtimeProvider.doubao)
                Text("OpenAI · 实时语音").tag(RealtimeProvider.openAI)
            }
            Text("她直接接收声音并用声音回应；字幕只用于显示与记忆核对。语音交流不需要 ElevenLabs 或本机对话模型。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("实时通话接通期间，麦克风音频、临时对话，以及开启自动记忆时的近期记忆会发送给\(realtime.provider.title)。\(controller.recordingDescription)。云端数据保留以服务商政策和账户设置为准。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if realtime.provider == .doubao {
                HStack {
                    Text("豆包语音凭证").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Link("去官网开通并获取凭证 ↗", destination: URL(string: "https://console.volcengine.com/speech/app")!).buttonStyle(.bordered)
                }
                Text("在火山引擎创建语音应用，开通「端到端实时语音大模型」，复制该应用的 App ID 和 Access Token。这里使用的是语音服务凭证。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Link("查看官方接入与凭证说明 ↗", destination: URL(string: "https://www.volcengine.com/docs/6561/1594356")!)
                    .font(.system(size: 11))
                TextField("App ID（与 Access Token 配对保存）", text: $realtime.appIDDraft).textFieldStyle(.roundedBorder)
            } else {
                Link("去官网获取 OpenAI API Key ↗", destination: URL(string: "https://platform.openai.com/settings/organization/api-keys")!).buttonStyle(.bordered)
            }
            HStack {
                SecureField(realtime.provider == .doubao ? "Access Token（保存后隐藏）" : "OpenAI API Key（保存后隐藏）", text: $realtime.keyDraft).textFieldStyle(.roundedBorder)
                Button("保存凭证") { controller.disableVoice(); realtime.saveKey() }
                    .disabled(realtime.keyDraft.isEmpty || (realtime.provider == .doubao && realtime.appIDDraft.isEmpty))
            }
            Text("密钥只存入 macOS 钥匙串，不进入网页组件或聊天。API 使用需要账户额度；这里不会自动购买。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if realtime.provider == .doubao {
                Text("豆包 O2.0 · 直接声音对话").font(.system(size: 12, weight: .medium))
                Picker("声音", selection: $realtime.voice) {
                    Text("VV · 女声").tag("zh_female_vv_jupiter_bigtts")
                    Text("Xiaohe · 女声，台湾口音").tag("zh_female_xiaohe_jupiter_bigtts")
                    Text("云舟 · 男声").tag("zh_male_yunzhou_jupiter_bigtts")
                    Text("小天 · 男声").tag("zh_male_xiaotian_jupiter_bigtts")
                }
                Text("自动记忆在本机提取，不影响声音对话。需要本机 Ollama 模型可用；提取失败时会提示本轮未保存。可在「慢慢记得」编辑或删除记忆。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                TextField("实时模型", text: $realtime.model).textFieldStyle(.roundedBorder)
                Picker("声音", selection: $realtime.voice) {
                    Text("Marin").tag("marin")
                    Text("Cedar").tag("cedar")
                }
            }
            Button("移除当前服务凭证") { controller.disableVoice(); realtime.removeKey() }
            Text(realtime.message).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("配置后回到「在你身边」，点“打电话”即可连接。点“挂电话”结束通话并停止收音。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: realtime.provider) { _, _ in controller.disableVoice() }
        .onChange(of: realtime.model) { _, _ in controller.disableVoice() }
        .onChange(of: realtime.voice) { _, _ in controller.disableVoice() }
        .onDisappear { realtime.keyDraft = ""; realtime.appIDDraft = "" }
    }
}
