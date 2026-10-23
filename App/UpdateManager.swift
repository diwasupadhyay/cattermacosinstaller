import Foundation
import Combine

@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    static let downloadURL = URL(string: "https://github.com/diwasupadhyay/catter/releases/latest")!
    @Published private(set) var availableVersion: String?
    @Published private(set) var notes = ""
    @Published private(set) var message = "Check for a newer version of Catter."
    @Published private(set) var checking = false
    private var checkedAt: Date?
    private struct Release: Decodable { let platform: String; let version: String; let notes: String }
    private struct Reply: Decodable { let releases: [Release] }
    static func newer(_ candidate: String, than current: String) -> Bool {
        func parts(_ value: String) -> [Int]? {
            let fields = value.split(separator: ".", omittingEmptySubsequences: false)
            guard fields.count == 3, fields.allSatisfy({ !$0.isEmpty && $0.count <= 4 && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return nil }
            let numbers = fields.compactMap { Int($0) }
            return numbers.count == 3 ? numbers : nil
        }
        guard let a = parts(candidate), let b = parts(current) else { return false }
        return b.lexicographicallyPrecedes(a)
    }
    func check(force: Bool = false) async {
        guard !checking, force || (checkedAt.map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true) else { return }
        checking = true
        defer { checking = false }
        do {
            guard let address = Bundle.main.object(forInfoDictionaryKey: "CatterAccessURL") as? String,
                  let base = URL(string: address), base.scheme == "https", base.host != nil,
                  base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
                  base.path.isEmpty || base.path == "/" else { throw URLError(.badURL) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 15
            configuration.httpCookieStorage = nil
            let session = URLSession(configuration: configuration, delegate: UpdateNoRedirects(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: base.appendingPathComponent("api/releases"))
            request.setValue("Catter/0.10.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 16384 else { throw URLError(.badServerResponse) }
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
            let release = reply.releases.first { $0.platform == "ios" && Self.newer($0.version, than: current) }
            availableVersion = release?.version
            notes = String((release?.notes ?? "").prefix(500))
            message = release == nil ? "You're up to date." : "A new version is available."
            checkedAt = Date()
        } catch { message = "Couldn't check for updates. Try again when you're online." }
    }
}
private final class UpdateNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
