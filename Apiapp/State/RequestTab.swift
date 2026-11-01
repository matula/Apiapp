import Foundation

enum RequestPaneKind: Hashable {
    case params, headers, auth, body
}

enum ResponsePaneKind: Hashable {
    case body, headers
}

enum RequestPhase: Equatable {
    case idle
    case sending
    case finished(ResponseDisplay)
    case failed(String)
    case cancelled
}

/// One open request. `baseline` is the version that's safely kept somewhere, so any
/// difference from it is work that closing the tab would lose.
struct RequestTab: Identifiable {
    let id: UUID
    var draft: RequestDraft
    var baseline: RequestDraft
    var savedRequestID: UUID?
    var historyEntryID: UUID?
    var savedResponseID: UUID?
    var requestPane = RequestPaneKind.body
    var responsePane = ResponsePaneKind.body
    var phase = RequestPhase.idle
    var bodyNotice: String?

    init(
        id: UUID = UUID(),
        draft: RequestDraft,
        baseline: RequestDraft? = nil,
        savedRequestID: UUID? = nil,
        historyEntryID: UUID? = nil,
        savedResponseID: UUID? = nil
    ) {
        self.id = id
        self.draft = draft
        self.baseline = baseline ?? draft
        self.savedRequestID = savedRequestID
        self.historyEntryID = historyEntryID
        self.savedResponseID = savedResponseID
    }

    var isDirty: Bool { draft != baseline }
    var isSending: Bool { phase == .sending }

    var response: ResponseDisplay? {
        if case .finished(let display) = phase { return display }
        return nil
    }
}
