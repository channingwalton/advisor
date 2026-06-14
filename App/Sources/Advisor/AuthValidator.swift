import Foundation

/// Validates a provider API key by making one cheap authenticated request
/// (a models list) directly to the provider — no sidecar spawn. Used by
/// Preferences so an invalid key surfaces immediately instead of failing
/// silently in a research lane at session time.
enum AuthValidator {
    enum Outcome: Equatable {
        case valid
        /// The key was rejected (HTTP 401/403).
        case invalid
        /// Could not determine validity (offline, timeout, unexpected status).
        case error(String)
    }

    /// Run the check for the given provider id ("codex" → OpenAI, anything else
    /// → Anthropic). An empty key short-circuits to `.invalid`.
    static func validate(provider: String, key: String) async -> Outcome {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalid }

        var request: URLRequest
        if provider == "codex" {
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        } else {
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
            request.setValue(trimmed, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        request.timeoutInterval = 15

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return interpret((response as? HTTPURLResponse)?.statusCode)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// Map an HTTP status to an outcome. Pure, so the policy is verifiable
    /// without a network call: 200 = valid, 401/403 = rejected key, anything
    /// else (incl. nil) = inconclusive error.
    static func interpret(_ status: Int?) -> Outcome {
        switch status {
        case 200: return .valid
        case 401, 403: return .invalid
        case let code?: return .error("Unexpected response (HTTP \(code))")
        case nil: return .error("No response from provider")
        }
    }
}
