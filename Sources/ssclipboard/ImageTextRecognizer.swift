import AppKit
import Foundation
@preconcurrency import Vision

enum ImageTextRecognizerError: LocalizedError {
    case couldNotCreateCGImage
    case recognitionFailed
    case noTextFound

    var errorDescription: String? {
        switch self {
        case .couldNotCreateCGImage:
            return "The screenshot could not be processed for text recognition."
        case .recognitionFailed:
            return "Text recognition failed. Please try again."
        case .noTextFound:
            return "No readable text was found in this screenshot."
        }
    }
}

enum ImageTextRecognizer {
    static func recognizeText(in image: NSImage) async throws -> String {
        guard let cgImage = image.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        ) else {
            throw ImageTextRecognizerError.couldNotCreateCGImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if error != nil {
                    continuation.resume(throwing: ImageTextRecognizerError.recognitionFailed)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(throwing: ImageTextRecognizerError.recognitionFailed)
                    return
                }

                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if text.isEmpty {
                    continuation.resume(throwing: ImageTextRecognizerError.noTextFound)
                } else {
                    continuation.resume(returning: text)
                }
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: ImageTextRecognizerError.recognitionFailed)
                }
            }
        }
    }
}
