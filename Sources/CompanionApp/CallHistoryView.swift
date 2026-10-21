import SwiftUI
import CompanionCore

struct CallHistoryView: View {
    @ObservedObject var model: CallHistoryModel
    @State private var selectedID: UUID?
    @State private var deleting: UUID?
    @State private var confirmDelete = false
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                if selectedID != nil {
                    Button { selectedID = nil } label: { Label("全部通话", systemImage: "chevron.left") }
                        .buttonStyle(.plain)
                }
                Text("聊过的话").font(.system(size: 28, design: .serif))
                Spacer()
                if !model.calls.isEmpty { Button("清空历史") { confirmClear = true }.buttonStyle(.plain) }
            }
            Text("文字只保存在本机，供你回看，不会自动把全部历史发给模型。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let error = model.error { Text(error).foregroundStyle(.orange).font(.callout).textSelection(.enabled) }
            if let call = model.calls.first(where: { $0.id == selectedID }) {
                HStack {
                    Text(call.startedAt.formatted(date: .abbreviated, time: .shortened))
                    Text(call.provider).foregroundStyle(.secondary)
                    Spacer()
                    Button("删除这次通话") { deleting = call.id; confirmDelete = true }
                }.font(.system(size: 12))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(call.lines) { line in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(line.role == "user" ? "你" : call.companion)
                                    Spacer()
                                    Text(line.time.formatted(date: .omitted, time: .shortened))
                                }.font(.system(size: 10)).foregroundStyle(.secondary)
                                Text(line.text).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
                Text(call.endedAt == nil ? "已保存的通话片段 · 尚无结束时间" : "通话已结束")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if model.calls.isEmpty {
                Spacer()
                Text("这里会留下聊过的话。").font(.title3)
                Text(model.enabled ? "从下一次通话开始保存文字，不保存录音。" : "历史保存已关闭，可在相处设置中开启。")
                    .foregroundStyle(.secondary).font(.callout)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.calls) { call in
                            Button { selectedID = call.id } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text(call.startedAt.formatted(date: .abbreviated, time: .shortened))
                                        Spacer()
                                        Text("\(call.lines.count) 条文字").foregroundStyle(.secondary)
                                        Image(systemName: "chevron.right")
                                    }.font(.system(size: 12))
                                    Text(String((call.lines.first(where: { $0.role == "user" })?.text ?? "一次通话").prefix(60)))
                                        .lineLimit(2).font(.system(size: 14))
                                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 14))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            Text("删除历史后，此前保留的通话只供回看；若正在使用续聊片段会结束通话。长期记忆与测试记录需分别管理。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(.horizontal, 34).padding(.bottom, 28)
        .confirmationDialog("删除这次通话记录？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除通话记录", role: .destructive) {
                if let deleting { model.delete(deleting); if selectedID == deleting { selectedID = nil } }
                deleting = nil
            }
        } message: { Text("删除后无法恢复。若正在使用旧通话续聊，会结束通话以撤回上下文；若删除的是当前通话，本次剩余文字也不再保存。长期记忆与测试记录不受影响。") }
        .confirmationDialog("清空所有通话历史？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空全部通话历史", role: .destructive) { model.clear(); selectedID = nil }
        } message: { Text("删除后无法恢复。若正在使用旧通话续聊，会结束通话；本次也不再追加历史。长期记忆与测试记录需分别清除。") }
    }
}
