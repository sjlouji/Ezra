import AVFoundation
@preconcurrency import Speech

enum DictationError: LocalizedError {
    case speechDenied, microphoneDenied, unavailable

    var errorDescription: String? {
        switch self {
        case .speechDenied:
            "macOS is not letting \(Brand.name) turn speech into text. Allow it in System Settings › Privacy & Security › Speech Recognition."
        case .microphoneDenied:
            "macOS is not letting \(Brand.name) use the microphone. Allow it in System Settings › Privacy & Security › Microphone."
        case .unavailable:
            "Dictation is not available on this Mac right now."
        }
    }
}

/// Turns what the user says into text, live. Recognition stays on the Mac where the system supports that.
@MainActor
@Observable
final class Dictation {
    private(set) var isListening = false
    /// What has been heard since `start`.
    private(set) var transcript = ""
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start() async throws {
        guard !isListening else { return }
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { throw DictationError.speechDenied }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw DictationError.microphoneDenied }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { throw DictationError.unavailable }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        transcript = ""
        Self.feed(engine.inputNode, into: request)
        engine.prepare()
        try engine.start()
        task = Self.recognise(request, with: recognizer) { [weak self] text, finished in
            Task { @MainActor in
                if let text { self?.transcript = text }
                if finished { self?.stop() }
            }
        }
        (self.request, isListening) = (request, true)
    }

    func stop() {
        guard isListening else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        (request, task, isListening) = (nil, nil, false)
    }

    /// The microphone hands over sound on its own thread, so this must not be tied to the main one.
    private nonisolated static func feed(_ input: AVAudioInputNode, into request: SFSpeechAudioBufferRecognitionRequest) {
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
    }

    private nonisolated static func recognise(
        _ request: SFSpeechAudioBufferRecognitionRequest, with recognizer: SFSpeechRecognizer,
        heard: @escaping @Sendable (String?, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            if let error { Log.assistant.error("Dictation stopped: \(String(describing: error), privacy: .public)") }
            heard(result?.bestTranscription.formattedString, (result?.isFinal ?? false) || error != nil)
        }
    }
}

import SwiftUI

/// A microphone button that dictates into a text field: what is said is added after what was already typed.
struct DictationButton: View {
    @Binding var text: String
    /// Called when listening ends by itself (the speaker stopped), not when the button stops it.
    var finished: () -> Void = {}
    @State private var dictation = Dictation()
    @State private var stoppedByHand = false
    @State private var typed = ""

    var body: some View {
        Button(dictation.isListening ? "Stop Dictation" : "Dictate", systemImage: dictation.isListening ? "mic.fill" : "mic") {
            if dictation.isListening {
                stoppedByHand = true
                dictation.stop()
            } else {
                (typed, stoppedByHand) = (text, false)
                Task {
                    do {
                        try await dictation.start()
                    } catch {
                        Alerts.shared.report("start dictation", error)
                    }
                }
            }
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(dictation.isListening ? Brand.Palette.deadline : Brand.Palette.secondary)
        .symbolEffect(.pulse, isActive: dictation.isListening)
        .help(dictation.isListening ? "Stop listening" : "Speak instead of typing")
        .onChange(of: dictation.transcript) {
            guard dictation.isListening || !dictation.transcript.isEmpty else { return }
            text = [typed.trimmed, dictation.transcript].filter { !$0.isEmpty }.joined(separator: " ")
        }
        .onChange(of: dictation.isListening) {
            if !dictation.isListening, !stoppedByHand, !dictation.transcript.isEmpty { finished() }
        }
        .onDisappear { dictation.stop() }
    }
}
