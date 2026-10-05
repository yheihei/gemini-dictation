import DictationCore
import SwiftUI

public struct SettingsView: View {
    @Bindable var model: SettingsModel
    private let height: CGFloat

    public init(model: SettingsModel, height: CGFloat = 720) {
        self.model = model
        self.height = height
    }

    public var body: some View {
        Form {
            apiKeySection
            modelSection
            shortcutSection
            dockSection
            permissionSection
            privacySection
        }
        .formStyle(.grouped)
        .frame(width: 580, height: height)
        .onAppear { model.refreshMicrophoneStatus() }
    }

    private var apiKeySection: some View {
        @Bindable var settings = model.settings
        return Section {
            LabeledContent("状態", value: model.keyStatusText)
            SecureField("APIキー", text: $model.draftKey, prompt: Text("Google AI Studioで作成したキーを貼り付け"))
                .onSubmit { model.saveKey() }
            Toggle("キーチェーンに保存する", isOn: $settings.storeKeyInKeychain)
                .onChange(of: settings.storeKeyInKeychain) { _, persist in
                    model.keychainSwitchChanged(to: persist)
                }
            HStack {
                Button("保存") { model.saveKey() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("削除", role: .destructive) { model.removeKey() }
                    .disabled(!model.keys.isConfigured)
                Spacer()
                Link("APIキーを作成（Google AI Studio）", destination: AppInfo.apiKeyURL)
            }
            if let message = model.keyMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(model.keyMessageIsError ? Color.red : Color.secondary)
            }
        } header: {
            Text("Gemini APIキー")
        } footer: {
            Text("オンにするとキーをキーチェーンに保存します。オフにするとキーチェーンから削除し、アプリを終了するまでメモリ上だけで保持します。キーはGeminiへのリクエストのヘッダー以外には使いません。")
        }
    }

    private var modelSection: some View {
        @Bindable var settings = model.settings
        return Section {
            Picker("モデル", selection: $settings.modelSelection) {
                ForEach(ModelCatalog.presets) { preset in
                    Text(preset.displayName).tag(preset.id)
                }
                Text("カスタム（モデルIDを入力）").tag(AppSettings.customModelTag)
            }
            if settings.isCustomModel {
                TextField("モデルID", text: $settings.customModelID, prompt: Text("例: gemini-3.5-flash-lite"))
                if settings.validCustomModelID == nil {
                    Text("有効なモデルIDを入力してください。入力するまでは標準モデルを使います。")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Text(settings.selectedModel.note)
                .font(.caption)
                .foregroundStyle(.secondary)
            Link("最新の料金（Gemini API 公式）", destination: AppInfo.pricingURL)
                .font(.caption)
        } header: {
            Text("モデル")
        }
    }

    private var shortcutSection: some View {
        let shortcuts = model.shortcuts
        return Section {
            LabeledContent("録音の開始／停止") {
                HStack(spacing: 8) {
                    Text(shortcuts.isRecording ? "キーを押してください…" : shortcuts.shortcut.displayName)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(shortcuts.isRecording ? Color.accentColor : Color.secondary.opacity(0.4))
                        )
                    if shortcuts.isRecording {
                        Button("キャンセル") { shortcuts.cancelRecording() }
                    } else {
                        Button("記録") { shortcuts.startRecording() }
                            .disabled(shortcuts.changesBlocked)
                        Button("fn に戻す") { shortcuts.resetToDefault() }
                            .disabled(shortcuts.changesBlocked || shortcuts.shortcut == .fn)
                    }
                }
            }
            if let feedback = shortcuts.feedback {
                Text(feedback.text)
                    .font(.caption)
                    .foregroundStyle(feedback.isError ? Color.red : Color.secondary)
            }
            if let status = model.shortcutStatusText {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(model.shortcutStatusIsWarning ? Color.orange : Color.secondary)
            }
            if shortcuts.changesBlocked && !shortcuts.isRecording {
                Text("録音中・文字起こし中は変更できません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("ショートカット")
        } footer: {
            Text("fn だけを0.5秒長押しすると録音を開始します。録音中は fn を1回押して離すだけで停止して文字起こしします。停止は長押しでもできます。開始した長押しのキーを離しても録音は続きます。録音開始前の短押しや、ほかのキー・修飾キー・クリック・スクロールとの組み合わせは反応しません。fn キーを使うにはアクセシビリティの許可が必要です。macOS のキーボード設定の「fnキーを押して」（地球儀キー）の動作もそのまま実行されるので、入力ソースの切り替えや絵文字が一緒に出る場合は「何もしない」にしてください。録音中と文字起こし中は esc でキャンセルできます。")
        }
    }

    private var dockSection: some View {
        @Bindable var settings = model.settings
        return Section {
            Toggle("Dock にアイコンを表示する", isOn: $settings.showInDock)
                .onChange(of: settings.showInDock) { _, _ in
                    model.dockPreferenceChanged()
                }
        } header: {
            Text("表示")
        } footer: {
            Text("オフのときはメニューバーだけに表示します。Dock のアイコンをクリックすると設定を開きます。録音中・文字起こし中に切り替えた場合は、終わってから反映します。Dock に固定するかどうかは macOS の Dock の設定で選べます。")
        }
    }

    private var permissionSection: some View {
        Section {
            LabeledContent("マイク") {
                HStack {
                    Text(model.microphoneStatusText)
                        .foregroundStyle(.secondary)
                    Button("システム設定を開く") { model.open(.microphone) }
                }
            }
            LabeledContent("アクセシビリティ") {
                HStack {
                    Text(model.accessibilityStatusText)
                        .foregroundStyle(.secondary)
                    if model.accessibilityTrusted != true {
                        Button("許可をリクエスト") { model.requestAccessibility() }
                    }
                    Button("システム設定を開く") { model.open(.accessibility) }
                }
            }
            Button("状態を確認") { model.checkPermissions() }
        } header: {
            Text("macOSの権限")
        } footer: {
            Text("アプリの起動や設定画面を開いただけでは許可を求めません。マイクは最初に録音を始めたときに確認します。アクセシビリティは、fn キーでの操作と、録音開始時の入力欄への自動貼り付けに使います。状態は「状態を確認」を押したとき、録音を始めたとき、fn キーを使う設定のときに調べます。このときmacOSがアプリをアクセシビリティの一覧にオフの状態で加えることがあります。許可しない場合は、結果をコピーして手動で貼り付けます。")
        }
    }

    private var privacySection: some View {
        Section {
            Text("Geminiに送信するのは、ショートカットまたはメニューで録音した音声だけです。クリップボード、入力中の文書、周囲のテキスト、アプリ名は送信しません。")
            Text("Gemini APIの利用には料金がかかる場合があります。無料枠では、Googleが送信内容を製品の改善に利用し、人間のレビュアーが読むことがあります。機密情報を話す場合は有料枠を使うか、このアプリを使わないでください。")
            Text("リクエストは store=false で送信し、Interactions APIのサーバー側の保存を無効にしています。このアプリは録音や文字起こし結果の履歴を残しません（コピー用に直前の結果だけをメモリ上に置き、終了時に消えます）。利用状況の解析データも送信しません。")
            Link("Gemini API 追加利用規約", destination: AppInfo.termsURL)
        } header: {
            Text("プライバシーと料金")
        }
        .font(.callout)
    }
}
