import Foundation

protocol LLMProvider: Sendable {
    func process(transcript: String, prompt: String) async throws -> String
}

// MARK: - Ollama Provider

struct OllamaProvider: LLMProvider {
    let endpoint: URL
    let model: String

    func process(transcript: String, prompt: String) async throws -> String {
        let fullPrompt = "\(prompt)\n\nTranscript:\n\(transcript)"

        let requestBody: [String: Any] = [
            "model": model,
            "prompt": fullPrompt,
            "stream": false
        ]

        let apiURL = URL(string: "/api/generate", relativeTo: endpoint)?.absoluteURL
            ?? endpoint.appendingPathComponent("api/generate")

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw LLMError.requestFailed("Ollama returned non-200 status")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseText = json["response"] as? String else {
            throw LLMError.invalidResponse
        }

        return responseText
    }
}

// MARK: - Claude CLI Provider

struct ClaudeCLIProvider: LLMProvider {
    func process(transcript: String, prompt: String) async throws -> String {
        let input = "\(prompt)\n\nTranscript:\n\(transcript)"
        return try await runCLI(command: "claude", arguments: ["-p", "-"], stdin: input)
    }
}

// MARK: - Gemini CLI Provider

struct GeminiCLIProvider: LLMProvider {
    func process(transcript: String, prompt: String) async throws -> String {
        let input = "\(prompt)\n\nTranscript:\n\(transcript)"
        return try await runCLI(command: "gemini", arguments: ["-p", "-"], stdin: input)
    }
}

// MARK: - CLI Helper

private func runCLI(command: String, arguments: [String], stdin input: String) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        let process = Process()
        let outputPipe = Pipe()
        let inputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.standardInput = inputPipe

        do {
            try process.run()
        } catch {
            continuation.resume(throwing: LLMError.cliNotFound(command))
            return
        }

        // Write transcript to stdin
        if let data = input.data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(data)
        }
        inputPipe.fileHandleForWriting.closeFile()

        process.waitUntilExit()

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            continuation.resume(throwing: LLMError.cliError(command, output))
        } else {
            continuation.resume(returning: output)
        }
    }
}

// MARK: - Errors

enum LLMError: Error, CustomStringConvertible {
    case requestFailed(String)
    case invalidResponse
    case cliNotFound(String)
    case cliError(String, String)

    var description: String {
        switch self {
        case .requestFailed(let reason): "LLM request failed: \(reason)"
        case .invalidResponse: "Invalid response from LLM"
        case .cliNotFound(let cli): "\(cli) CLI not found. Please install it first."
        case .cliError(let cli, let output): "\(cli) CLI error: \(output)"
        }
    }
}
