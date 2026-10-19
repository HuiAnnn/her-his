import SwiftUI
import AppKit
import CompanionCore

private enum Palette {
    static let background = Color(red: 0.075, green: 0.080, blue: 0.084)
    static let panel = Color(red: 0.105, green: 0.112, blue: 0.116)
    static let cream = Color(red: 0.91, green: 0.88, blue: 0.81)
    static let accent = Color(red: 0.75, green: 0.81, blue: 0.69)
    static let muted = Color(red: 0.50, green: 0.55, blue: 0.53)
}

struct CompanionRootView: View {
    @ObservedObject var model: CompanionController
    @State private var editing: CompanionMemory?
    @State private var editText = ""
    @State private var confirmClear = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(.white.opacity(0.06)).frame(width: 1)
            VStack(spacing: 0) {
                topbar
                if let error = model.errorText {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle").foregroundStyle(Palette.cream)
                        Text(error).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button { model.errorText = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }
                    .padding(14).background(Color.orange.opacity(0.09)).clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 32).padding(.bottom, 12)
                }
                switch model.selectedPage {
                case "memories": memoryPage
                case "settings": settingsPage
                default: presencePage
                }
            }
        }
        .background(alignment: .bottomTrailing) {
            if let driver = model.realtime.openAIDriver as? RealtimeWebRTC {
                RealtimeMediaHost(driver: driver).frame(width: 2, height: 2).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .background(alignment: .bottomTrailing) {
            if let driver = model.realtime.doubaoDriver as? DoubaoRealtime {
                DoubaoMediaHost(driver: driver).frame(width: 2, height: 2).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .background(Palette.background)
        .foregroundStyle(Palette.cream)
        .frame(minWidth: 900, minHeight: 700)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showWelcome) { welcome }
        .sheet(item: $editing) { item in
            VStack(alignment: .leading, spacing: 20) {
                Text("重新认识这一点").font(.title2)
                Text("记忆可以随着你改变。修改后，旧内容不会再用于新的回应。")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $editText).font(.body).frame(height: 120)
                    .padding(10).background(.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 10))
                HStack {
                    Button("取消") { editing = nil }
                    Spacer()
                    Button("保存更改") { model.editMemory(item.id, content: editText); editing = nil }
                        .buttonStyle(.borderedProminent).tint(Palette.accent).foregroundStyle(Palette.background)
                        .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editText.count > 240)
                }
            }.padding(28).frame(width: 440).preferredColorScheme(.dark)
        }
        .confirmationDialog("忘掉所有记忆？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除全部记忆", role: .destructive) { model.clearMemories() }
        } message: { Text("已有记忆会从本机删除，当前临时对话也会清空。自动记忆开关不受影响。") }
        .task { await model.checkConnection() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle").font(.system(size: 23, weight: .light)).foregroundStyle(Palette.accent)
                Text("在场").font(.system(size: 24, weight: .medium, design: .serif))
            }.padding(.top, 36).padding(.bottom, 9)
            Text("HER / HIS").font(.system(size: 9, weight: .medium)).tracking(3).foregroundStyle(Palette.muted)
                .padding(.leading, 1).padding(.bottom, 48)
            navItem("在你身边", symbol: "waveform", page: "presence")
            navItem("慢慢记得", symbol: "leaf", page: "memories")
            navItem("相处设置", symbol: "slider.horizontal.3", page: "settings")
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Circle().fill(model.modelAvailable ? Palette.accent : Palette.muted).frame(width: 5, height: 5)
                    Text(model.realtime.enabled ? (model.realtime.isActive ? "云端实时陪伴" : "实时语音 · 等你开启") : (model.modelAvailable ? "本机陪伴" : (model.checkingConnection ? "正在准备本机陪伴…" : "等待模型连接"))).font(.system(size: 11))
                }
                Text(model.realtime.enabled ? "呼唤在本机。\n实时对话会传送音频。" : "麦克风与记忆在本机。\n云端声音可在设置开启。").font(.system(size: 11)).lineSpacing(5).foregroundStyle(Palette.muted)
            }.padding(.bottom, 30)
        }
        .padding(.horizontal, 24).frame(width: 188).background(Palette.panel.opacity(0.45))
    }
    private func navItem(_ title: String, symbol: String, page: String) -> some View {
        Button { model.selectedPage = page } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 15)).frame(width: 19)
                Text(title).font(.system(size: 13))
                Spacer(minLength: 0)
                if page == "memories", !model.memories.isEmpty { Text("\(model.memories.count)").font(.system(size: 10)) }
            }
            .foregroundStyle(model.selectedPage == page ? Palette.cream : Palette.muted)
            .padding(.vertical, 13).padding(.horizontal, 12)
            .background(model.selectedPage == page ? Color.white.opacity(0.055) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).padding(.horizontal, -10).padding(.bottom, 7)
    }
    private var topbar: some View {
        HStack {
            Text(model.selectedPage == "presence" ? "一段属于你的时间" : (model.selectedPage == "memories" ? "在相处里，慢慢了解你" : "让相处更自在"))
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: model.microphoneRunning ? "mic" : "mic.slash").font(.system(size: 11))
                Text(model.micDescription).font(.system(size: 10))
            }.foregroundStyle(model.microphoneRunning ? Palette.accent : Palette.muted)
        }.padding(.horizontal, 34).padding(.top, 28).padding(.bottom, 24)
    }
    private var presencePage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 4)
            PresenceOrb(active: model.phase == .speaking || model.phase == .thinking, level: model.level)
                .frame(height: model.lines.isEmpty ? 196 : 130)
            Text(model.phase.title).font(.system(size: model.lines.isEmpty ? 30 : 23, weight: .regular, design: .serif))
                .padding(.top, 8)
            Text(model.realtime.isActive ? (model.realtime.state == .connecting ? "接通后再说话，稍等一下。" : "声音直接相连，你可以随时插话。") : (model.wakeEnabled ? "叫一声「\(model.companionName)」，想说什么都可以。" : "想说话的时候，我在。"))
                .font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.top, 12)
            if model.lines.isEmpty {
                Spacer(minLength: 28)
                Text("不必准备话题，也不必填满安静。")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted.opacity(0.8))
                    .padding(.bottom, 30)
            } else {
                conversation.padding(.top, 24)
            }
            if !model.partial.isEmpty {
                Text(model.partial).font(.system(size: 12)).foregroundStyle(Palette.accent)
                    .lineLimit(2).padding(.horizontal, 36).padding(.bottom, 10)
            }
            controls.padding(.top, 20).padding(.bottom, 24)
            composer.padding(.horizontal, 34).padding(.bottom, 14)
            if !model.realtime.memoryContextStatus.isEmpty {
                Text(model.realtime.memoryContextStatus).font(.caption).foregroundStyle(Palette.muted)
            }
            Text(model.testRecordingEnabled ? "本机测试记录开启 · 正在保存对话文字" : "本机不保存完整聊天 · 记忆由你随时管理")
                .font(.system(size: 9)).foregroundStyle(Palette.muted.opacity(0.7)).padding(.bottom, 22)
        }
    }
    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 17) {
                    ForEach(model.lines) { line in
                        HStack(alignment: .top, spacing: 10) {
                            if line.role == "user" { Spacer(minLength: 45) }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(line.role == "user" ? "你" : model.companionName)
                                    .font(.system(size: 9)).foregroundStyle(Palette.muted)
                                Text(line.text).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                            }
                            .padding(14)
                            .background(line.role == "user" ? Color.white.opacity(0.045) : Palette.accent.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            if line.role != "user" { Spacer(minLength: 45) }
                        }.id(line.id)
                    }
                    if model.phase == .thinking {
                        HStack(spacing: 6) {
                            ForEach(0..<3) { _ in Circle().fill(Palette.accent.opacity(0.5)).frame(width: 4, height: 4) }
                            Text("在想你刚刚说的话").font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }.padding(.leading, 14)
                    }
                }.padding(.horizontal, 34).padding(.bottom, 10)
            }
            .frame(minHeight: 110, maxHeight: 240)
            .onChange(of: model.lines.count) { _, _ in
                if let last = model.lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }
    private var controls: some View {
        HStack(spacing: 12) {
            if !model.wakeEnabled {
                Button { model.enableVoice() } label: {
                    Label("开启语音陪伴", systemImage: "waveform").font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 22).padding(.vertical, 13)
                        .foregroundStyle(Palette.background).background(Palette.accent).clipShape(Capsule())
                }.buttonStyle(.plain)
                if model.realtime.enabled {
                    Button("直接聊聊") { model.enableVoice(startConversation: true) }.buttonStyle(.bordered)
                }
            } else {
                circleButton(model.isMuted ? "mic.slash.fill" : "mic.fill", help: model.isMuted ? "取消静音" : "静音麦克风") {
                    model.isMuted ? model.unmute() : model.mute()
                }
                Button { model.enableVoice(startConversation: true) } label: {
                    Text(model.canEnd ? "重新开始" : "直接聊聊").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 24).padding(.vertical, 13)
                        .foregroundStyle(Palette.background).background(Palette.accent).clipShape(Capsule())
                }.buttonStyle(.plain).disabled(model.phase == .connecting)
                circleButton("power", help: "完全关闭麦克风与唤起") { model.disableVoice() }
            }
            if model.phase == .speaking || model.phase == .thinking {
                circleButton("stop.fill", help: "打断回应") { model.interrupt() }
            }
            if model.canEnd {
                Button("结束这次对话") { model.endConversation() }.buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }
    }
    private func circleButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14)).frame(width: 41, height: 41)
            .background(.white.opacity(0.05)).clipShape(Circle()) }
            .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
    private var composer: some View {
        HStack(spacing: 12) {
            TextField("也可以在这里写一句话…", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 12)).lineLimit(1...3)
                .onSubmit { model.sendDraft() }
            Button { model.sendDraft() } label: {
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(model.draft.isEmpty ? Palette.muted : Palette.background)
                    .frame(width: 28, height: 28).background(model.draft.isEmpty ? Color.white.opacity(0.04) : Palette.accent).clipShape(Circle())
            }.buttonStyle(.plain).disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isMuted || model.phase == .connecting)
                .accessibilityLabel("发送")
        }.padding(.horizontal, 16).padding(.vertical, 12)
            .background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(.white.opacity(0.05), lineWidth: 1))
    }

    private var memoryPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("慢慢记得").font(.system(size: 29, design: .serif))
                    Text("在聊天中自然记住，也随时可以忘掉。")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Toggle("自动记忆", isOn: Binding(get: { model.memoryEnabled }, set: model.setMemoryEnabled))
                    .toggleStyle(.switch).font(.system(size: 12)).tint(Palette.accent)
            }
            if model.memories.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "leaf").font(.system(size: 35, weight: .ultraLight)).foregroundStyle(Palette.accent)
                    Text("我们可以慢慢认识").font(.system(size: 19, design: .serif))
                    Text("你分享的喜好、近况与重要的小事，会在这里留下简短的记忆。")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.memories) { item in
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    Text(item.key == "birthday" ? "关于你" : item.kind.rawValue == "preference" ? "你的偏好" : (item.kind.rawValue == "event" ? "最近的事" : "相处边界"))
                                        .font(.system(size: 10)).foregroundStyle(Palette.accent)
                                    Spacer()
                                    Text(item.updatedAt, style: .date).font(.system(size: 9)).foregroundStyle(Palette.muted)
                                    Button { editing = item; editText = item.content } label: { Image(systemName: "pencil") }.buttonStyle(.plain).help("纠正这条记忆")
                                    Button { model.deleteMemory(item.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain).help("忘掉这条记忆")
                                }
                                Text(item.content).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                            }.padding(20).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 15))
                        }
                    }
                }
            }
            HStack {
                Text(model.testRecordingEnabled ? "本机测试记录开启 · 保存对话文字，不保存录音" : (model.memoryEnabled ? "自动保存开启 · 不保存完整聊天或录音" : "新记忆暂停保存 · 已有记忆仍可用于对话"))
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
                Spacer()
                if !model.memories.isEmpty { Button("清除全部") { confirmClear = true }.buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 11)) }
            }
        }.padding(.horizontal, 34).padding(.bottom, 28)
    }

    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("舒服的相处方式").font(.system(size: 28, design: .serif))
                settingCard("怎么称呼她", caption: "开启唤起后，在一句话开头叫这个名字。") {
                    TextField("名字", text: $model.companionName).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    Text("建议 2–8 个字。叫名字唤起仍需要在本机验证准确性。")
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                settingCard("实时语音", caption: "像通话一样交流，声音直接传入模型。") {
                    RealtimeSettingsView(realtime: model.realtime, controller: model)
                }
                settingCard("本机测试记录", caption: "用于排查漏记和对话问题，与长期记忆分开保存。") {
                    Toggle("保存测试对话", isOn: Binding(get: { model.testRecordingEnabled }, set: model.setTestRecordingEnabled))
                    Text("仅本机保存对话文字和记忆处理结果，不保存录音或服务密钥。新增时清理7天前内容，最多1000条；关闭后停止新增，已有记录可手动清空。隐私回合或原话未就绪的回答会省略。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack {
                        Button("查看测试记录") { NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: model.testJournalURL.path) ? model.testJournalURL : model.testJournalURL.deletingLastPathComponent()]) }
                        Button("清空测试记录") { model.clearTestRecords() }
                    }
                    if let error = model.testRecordingError { Text(error).font(.system(size: 12)).foregroundStyle(.orange) }
                }
                if !model.realtime.enabled {
                settingCard("本机对话模型", caption: "打开在场时会自动准备本机引擎，不需要另外启动 Ollama。") {
                    HStack {
                        TextField("模型名称", text: $model.modelName).textFieldStyle(.roundedBorder)
                        Button(model.checkingConnection ? "准备中…" : "重新连接") { Task { await model.checkConnection() } }
                            .disabled(model.checkingConnection)
                    }
                    Text(model.status).font(.system(size: 11)).foregroundStyle(model.modelAvailable ? Palette.accent : Palette.muted)
                    Button("打开 Ollama") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Ollama.app")) }
                }
                settingCard("语音与安静", caption: "你开口，她回应；你安静，她也安静。") {
                    CloudVoiceSettingsView(output: model.cloudVoice, controller: model)
                    Text("本机听写必须可用才会开启语音，不会自动退回云端识别。外放插话效果需实机确认，建议先用耳机体验。")
                        .font(.system(size: 12)).lineSpacing(5).foregroundStyle(.secondary)
                    Text("“结束这次对话”回到等待呼唤；电源按钮彻底关闭输入。Mac 休眠时不承诺可唤起。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                }
                HStack {
                    Button("保存设置") { model.saveSettings() }.buttonStyle(.borderedProminent).tint(Palette.accent).foregroundStyle(Palette.background)
                    Spacer()
                    Button("查看数据位置") { NSWorkspace.shared.activateFileViewerSelecting([model.dataURL]) }.buttonStyle(.plain).foregroundStyle(Palette.muted).font(.system(size: 11))
                }
            }.padding(.horizontal, 34).padding(.bottom, 32)
        }
    }
    private func settingCard<Content: View>(_ title: String, caption: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 15, weight: .medium))
            Text(caption).font(.system(size: 11)).foregroundStyle(Palette.muted)
            content()
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 16))
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "sparkle").font(.system(size: 30)).foregroundStyle(Palette.accent)
            Text("想说话的时候，我在。").font(.system(size: 26, design: .serif))
            Text("这是一个 AI 语音陪伴者。你先开口，她才回应；也可以一起安静待着。")
                .font(.system(size: 14)).lineSpacing(6)
            VStack(alignment: .leading, spacing: 13) {
                Label("语音由你主动开启，应用不保存录音。", systemImage: "mic")
                Label("可选本机对话，或直接传送音频的云端实时对话。", systemImage: "desktopcomputer")
                Label("本机模式也可单独选用 ElevenLabs 声音。", systemImage: "waveform")
                Label("自动记住有用的小事，随时查看、纠正或删除。", systemImage: "leaf")
            }.font(.system(size: 12)).foregroundStyle(.secondary)
            Text("本机对话引擎会自动准备。开启语音时，macOS 会询问麦克风和语音识别权限。")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            Button("从这里开始") { model.acknowledgeWelcome() }
                .buttonStyle(.borderedProminent).tint(Palette.accent).foregroundStyle(Palette.background).controlSize(.large)
        }.padding(36).frame(width: 470).background(Palette.background).preferredColorScheme(.dark)
    }
}

private struct PresenceOrb: View {
    let active: Bool
    let level: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false
    var body: some View {
        ZStack {
            Circle().fill(Palette.accent.opacity(0.055)).frame(width: 190, height: 190).blur(radius: 24)
            Circle().stroke(Palette.accent.opacity(0.08), lineWidth: 1).frame(width: 154, height: 154)
            Circle().stroke(Palette.accent.opacity(0.15), lineWidth: 0.6).frame(width: 135, height: 135)
            Circle().fill(RadialGradient(colors: [Color(red: 0.81, green: 0.86, blue: 0.71), Color(red: 0.40, green: 0.51, blue: 0.39), Color(red: 0.14, green: 0.21, blue: 0.18)], center: .init(x: 0.35, y: 0.26), startRadius: 1, endRadius: 100))
                .frame(width: 112, height: 112)
                .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
                .shadow(color: Palette.accent.opacity(0.14), radius: 22)
                .scaleEffect(reduceMotion ? 1 : (breathe ? 1.04 : 0.96) + Double(min(level, 0.25)) * 0.08)
            Circle().fill(.white.opacity(0.18)).frame(width: 28, height: 22).blur(radius: 12).offset(x: -20, y: -26)
        }
        .scaleEffect(active ? 1.06 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: active)
        .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true)) { breathe = true } } }
        .accessibilityHidden(true)
    }
}
