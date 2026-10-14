import Foundation

/// Reports every request a background job sends and what came back, so the Activity window can show exactly what the
/// AI is doing. Pipelines only call `send`; a tool loop on Apple's model needs the unwrapped provider.
public struct ObservedProvider: LLMProvider {
    public enum Event: Sendable {
        case request(ChatRequest)
        case reply(ChatResponse, seconds: TimeInterval)
        case failed(String, seconds: TimeInterval)
    }

    public let base: LLMProvider
    public let onEvent: @Sendable (Event) -> Void
    public var descriptor: ProviderDescriptor { base.descriptor }

    public init(_ base: LLMProvider, onEvent: @escaping @Sendable (Event) -> Void) {
        self.base = base; self.onEvent = onEvent
    }

    public func send(_ request: ChatRequest) async throws -> ChatResponse {
        onEvent(.request(request))
        let start = Date()
        do {
            let r = try await base.send(request)
            onEvent(.reply(r, seconds: Date().timeIntervalSince(start)))
            return r
        } catch {
            onEvent(.failed((error as? LocalizedError)?.errorDescription ?? "\(error)", seconds: Date().timeIntervalSince(start)))
            throw error
        }
    }

    public func listModels() async throws -> [ModelInfo] { try await base.listModels() }
}
