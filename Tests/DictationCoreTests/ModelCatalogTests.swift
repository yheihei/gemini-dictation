import Testing
@testable import DictationCore

@Suite("Model catalog")
struct ModelCatalogTests {
    @Test func defaultIsTheLowCostStableFlashLite() {
        let model = ModelCatalog.model(for: ModelCatalog.defaultModelID)
        #expect(model.id == "gemini-3.5-flash-lite")
        #expect(model.engine == .generative)
        #expect(model.thinkingLevel == "minimal")
        #expect(ModelCatalog.presets.first?.id == ModelCatalog.defaultModelID)
    }

    @Test func presetsAreUniqueValidAndCurrent() {
        let ids = ModelCatalog.presets.map(\.id)
        #expect(Set(ids).count == ids.count)
        for id in ids {
            #expect(ModelCatalog.normalizedModelID(id) == id)
            // 2.x models are restricted to existing users; preview IDs get shut down.
            #expect(!id.hasPrefix("gemini-2."))
            #expect(!id.contains("preview"))
        }
    }

    @Test func transcribeModelUsesTheDedicatedEngine() {
        let model = ModelCatalog.model(for: "gemini-3.5-transcribe")
        #expect(model.engine == .transcribe)
        #expect(model.thinkingLevel == nil)
    }

    @Test func customModelsUseModelDefaults() {
        let custom = ModelCatalog.model(for: "gemini-9.9-flash")
        #expect(custom.engine == .generative)
        #expect(custom.thinkingLevel == nil)
        #expect(ModelCatalog.model(for: "gemini-9.9-transcribe").engine == .transcribe)
    }

    @Test(arguments: [
        ("  gemini-3.5-flash-lite \n", "gemini-3.5-flash-lite"),
        ("models/gemini-3.8-flash", "gemini-3.8-flash"),
        ("gemini_custom.v2-1", "gemini_custom.v2-1"),
    ])
    func normalizesValidModelIDs(raw: String, expected: String) {
        #expect(ModelCatalog.normalizedModelID(raw) == expected)
    }

    @Test(arguments: ["", "   ", "gemini 3", "../etc", "gemini/3", "-flash", "ジェミニ", "gemini-3?key=x"])
    func rejectsInvalidModelIDs(raw: String) {
        #expect(ModelCatalog.normalizedModelID(raw) == nil)
    }
}
