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
        @Bindable var settings = model.settings
        return Section {
            Picker("録音の開始／停止", selection: $settings.hotKeyPreset) {
                ForEach(HotKeyPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            if !model.hotKeyRegistered {
                Text("このショートカットを登録できませんでした。別の組み合わせを選んでください。")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("ショートカット")
        } footer: {
            Text("録音中と文字起こし中は esc でキャンセルできます。メニューバーのマイクアイコンからも操作できます。")
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
            Text("アプリの起動や設定画面を開いただけでは許可を求めません。マイクは最初に録音を始めたときに確認します。アクセシビリティは録音開始時の入力欄へ自動で貼り付けるために使い、「状態を確認」を押したときと録音を始めたときに状態を調べます。このときmacOSがアプリをアクセシビリティの一覧にオフの状態で加えることがあります。許可しない場合は、結果をコピーして手動で貼り付けます。")
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
