import Core
import SwiftUI

struct LocalTendenciesView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case tendencies = "傾向"
        case conversions = "変換の学習"
        var id: String { rawValue }
    }

    @State private var client = ConverterServerClient()
    @State private var section: Section = .tendencies
    @State private var entries: [LocalTendency] = []
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch section {
            case .tendencies: tendencies
            case .conversions: LearnedConversionsView(client: client)
            }
        }
        .padding()
    }

    private var tendencies: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("学習した傾向").font(.title2)
            Text("このMacで確定した文章から学習します。現在の文章の文脈を優先します。削除後も、新しい入力からは再学習します。")
                .font(.callout)
            if let error { Text(error).foregroundStyle(.red) }
            if entries.isEmpty { Text("学習した傾向はまだありません。").foregroundStyle(.secondary) }
            List(entries, id: \.key) { entry in
                TendencyRow(entry: entry, save: { value in
                    perform(.edit(key: entry.key, value: value))
                }, delete: { perform(.delete(key: entry.key)) })
            }
            HStack {
                Button("更新") { perform(.list) }
                Spacer()
                Button("すべて削除", role: .destructive) { perform(.deleteAll) }
                    .disabled(entries.isEmpty)
            }
        }
        .disabled(busy)
        .onAppear { perform(.list) }
    }

    private func perform(_ command: LocalLearningCommand) {
        busy = true
        error = nil
        client.send({ _ in .learning(command) }) { response in
            DispatchQueue.main.async {
                busy = false
                if let values = response?.localTendencies {
                    entries = values
                    if response?.learningFailed == true {
                        error = "今回の起動中に学習処理の失敗がありました。変換は継続します。保存先の空き容量・権限を確認してください。"
                    }
                }
                else { error = "学習データを更新できませんでした。変換プロセスの起動状態を確認してください。" }
            }
        }
    }
}

/// Words the converter learned from commits; wrongly learned ones (「ご変換」) can be
/// removed here instead of with a developer tool.
private struct LearnedConversionsView: View {
    let client: ConverterServerClient
    @State private var items: [LearnedConversion] = []
    @State private var query = ""
    @State private var suspiciousOnly = false
    @State private var selection = Set<LearnedConversion>()
    @State private var error: String?
    @State private var busy = false
    @State private var confirming = false

    private var shown: [LearnedConversion] {
        let katakanaQuery = query.applyingTransform(.hiraganaToKatakana, reverse: false) ?? query
        return items.filter { item in
            (!suspiciousOnly || item.hasPendingRomaji)
                && (query.isEmpty || item.word.localizedCaseInsensitiveContains(query)
                    || item.reading.localizedCaseInsensitiveContains(katakanaQuery))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("変換の学習").font(.title2)
            Text("確定した変換から覚えた語です。間違って覚えたもの（例:「ごへんかん」→「ご変換」）を選んで削除すると、次の変換から使われなくなります。同じ表記の学習は、すべての読みでまとめて削除されます。")
                .font(.callout)
            HStack {
                TextField("表記または読みで検索", text: $query)
                Toggle("ローマ字が残った断片だけ", isOn: $suspiciousOnly)
            }
            if let error { Text(error).foregroundStyle(.red) }
            List(shown, id: \.self, selection: $selection) { item in
                HStack {
                    Text(item.word)
                    Spacer()
                    Text(item.reading).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("\(items.count) 件（表示 \(shown.count) 件）").foregroundStyle(.secondary)
                Button("更新") { load() }
                Spacer()
                Button("選択した \(selection.count) 件を削除", role: .destructive) { confirming = true }
                    .disabled(selection.isEmpty)
            }
        }
        .disabled(busy)
        .onAppear { load() }
        .confirmationDialog("選択した \(selection.count) 件の学習を削除しますか？", isPresented: $confirming) {
            Button("削除", role: .destructive) { forget() }
        }
    }

    private func load() {
        busy = true
        error = nil
        client.listLearnedConversions { result in
            DispatchQueue.main.async { finish(result) }
        }
    }

    private func forget() {
        busy = true
        error = nil
        client.forgetLearnedConversions(Array(selection)) { result in
            DispatchQueue.main.async {
                selection.removeAll()
                finish(result)
            }
        }
    }

    private func finish(_ result: [LearnedConversion]?) {
        busy = false
        if let result {
            items = result.sorted { $0.reading == $1.reading ? $0.word < $1.word : $0.reading < $1.reading }
        } else {
            error = "変換の学習を読み込めませんでした。変換プロセスの起動状態を確認してください。"
        }
    }
}

private struct TendencyRow: View {
    let entry: LocalTendency
    let save: (String) -> Void
    let delete: () -> Void
    @State private var value: String = ""

    var body: some View {
        HStack {
            TextField("傾向", text: $value)
            Button("保存") { save(value) }.disabled(value.isEmpty || value == entry.value)
            Button("削除", role: .destructive, action: delete)
        }
        .onAppear { value = entry.value }
        .onChange(of: entry.value) { updated in value = updated }
    }
}
