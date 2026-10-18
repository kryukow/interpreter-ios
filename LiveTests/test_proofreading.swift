import Foundation

func mode(_ original: String, _ target: String, _ detected: String?, _ enabled: Bool = true) -> VoiceTextProcessingPolicy.Mode {
    VoiceTextProcessingPolicy.mode(
        original: original, targetLanguage: target,
        detectedLanguage: detected, proofreadingEnabled: enabled)
}

assert(mode("превет филипп как дила", "ru", "ru") == .proofreadRussian)
assert(mode("превет филипп как дила", "ru", nil) == .proofreadRussian)
assert(mode("превет филипп как дила", "de", "ru") == .translate)
assert(mode("Ich bin morgen da.", "ru", "de") == .translate)
assert(mode("Ich bin morgen da.", "de", "de") == .unchanged)
assert(mode("превет филипп как дила", "ru", "ru", false) == .unchanged)
assert(mode("   ", "ru", "ru") == .unchanged)
assert(mode(VoiceSynthesisLanguage.sample(for: "ru")!, "ru", "ru") == .unchanged)
assert(mode("Hei!", "no", "nb") == .unchanged)
assert(mode("Hei!", "en", "nb") == .translate)
assert(VoiceTextProcessingPolicy.russianProofreadingInstructions.contains("Do not translate"))
assert(VoiceTextProcessingPolicy.russianProofreadingInstructions.contains("conversational or formal tone"))
print("Russian proofread / language routing: passed")
