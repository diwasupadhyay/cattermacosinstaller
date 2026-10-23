// Native adaptation of iPASide developer.py (MIT, Copyright 2026 iPASide
// Contributors). See Licenses/iPASide.txt. Only renew an EXISTING App ID:
// no automatic certificate revocation, team changes or App ID deletion.
import Foundation

struct AppleRenewalSession {
    let accountID: String
    let token: String
}

enum AppleProvisioningError: Error, Equatable {
    case missingAuthentication, invalidHeaders, invalidIdentifier, rejectedHTTP(Int)
    case rejectedResult(Int), malformedResponse, responseTooLarge, missingProfile
}

final class AppleProvisioningClient {
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    private let session: URLSession?
    init(transport: Transport? = nil) {
        if let transport { self.transport = transport; self.session = nil }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 45
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration, delegate: AppleRenewalNoRedirects(), delegateQueue: nil)
            self.session = session
            self.transport = { request in
                let (data, reply) = try await session.data(for: request)
                guard let response = reply as? HTTPURLResponse else { throw AppleProvisioningError.malformedResponse }
                return (data, response)
            }
        }
    }
    deinit { session?.invalidateAndCancel() }

    // Only a fixed allowlist of anisette headers can accompany an Apple request.
    // A provider cannot override Authorization, Host or our account identity.
    static func request(endpoint: String, authentication: AppleRenewalSession,
                        anisette: [String: String], team: String?, parameters: [String: Any] = [:]) throws -> URLRequest {
        let endpoints = ["listTeams.action", "ios/listAppIds.action", "ios/listAllDevelopmentCerts.action", "ios/downloadTeamProvisioningProfile.action"]
        guard endpoints.contains(endpoint) else { throw AppleProvisioningError.invalidIdentifier }
        func valid(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 8192 && !value.contains("\r") && !value.contains("\n") }
        guard valid(authentication.accountID), valid(authentication.token) else { throw AppleProvisioningError.missingAuthentication }
        if let team { guard !team.isEmpty, team.count <= 128, team.allSatisfy({ $0.isASCII && $0.isLetter || $0.isASCII && $0.isNumber }) else { throw AppleProvisioningError.invalidIdentifier } }
        let allowed = Set(["X-Apple-I-MD", "X-Apple-I-MD-M", "X-Apple-I-MD-LU", "X-Apple-I-MD-RINFO", "X-Mme-Device-Id", "X-MMe-Client-Info", "X-Apple-I-Client-Time", "X-Apple-I-TimeZone", "X-Apple-Locale"])
        guard anisette["X-Apple-I-MD"] != nil, anisette["X-Apple-I-MD-M"] != nil,
              anisette.allSatisfy({ allowed.contains($0.key) && valid($0.value) }) else { throw AppleProvisioningError.invalidHeaders }
        guard parameters.keys.allSatisfy({ $0 == "appIdId" }) else { throw AppleProvisioningError.invalidIdentifier }
        if let appID = parameters["appIdId"] {
            guard let id = appID as? String, valid(id), id.count <= 128 else { throw AppleProvisioningError.invalidIdentifier }
        }
        let url = URL(string: "https://developerservices2.apple.com/services/QH65B2/" + endpoint + "?clientId=XABBG36SBA")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        var headers = anisette
        headers["Content-Type"] = "text/x-xml-plist"
        headers["Accept"] = "text/x-xml-plist"
        headers["User-Agent"] = "Xcode"
        headers["X-Apple-App-Info"] = "com.apple.gs.xcode.auth"
        headers["X-Xcode-Version"] = "11.2 (11B41)"
        headers["X-Apple-I-Identity-Id"] = authentication.accountID
        headers["X-Apple-GS-Token"] = authentication.token
        headers["X-Apple-I-Locale"] = anisette["X-Apple-Locale"] ?? "en_US"
        request.allHTTPHeaderFields = headers
        var body: [String: Any] = ["clientId": "XABBG36SBA", "protocolVersion": "QH65B2", "requestId": UUID().uuidString.uppercased()]
        if let team { body["teamId"] = team }
        for (key, value) in parameters { body[key] = value }
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        return request
    }

    func request(endpoint: String, authentication: AppleRenewalSession, anisette: [String: String],
                 team: String?, parameters: [String: Any] = [:]) async throws -> [String: Any] {
        let request = try Self.request(endpoint: endpoint, authentication: authentication, anisette: anisette, team: team, parameters: parameters)
        let (data, response) = try await transport(request)
        guard response.statusCode == 200 else { throw AppleProvisioningError.rejectedHTTP(response.statusCode) }
        guard data.count <= 4 * 1024 * 1024 else { throw AppleProvisioningError.responseTooLarge }
        guard let body = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let rawCode = body["resultCode"], let code = Int(String(describing: rawCode)) else { throw AppleProvisioningError.malformedResponse }
        // Do not display Apple's arbitrary error text: it may contain identifiers.
        guard code == 0 else { throw AppleProvisioningError.rejectedResult(code) }
        return body
    }

    func downloadExistingProfile(team: String, appID: String, authentication: AppleRenewalSession,
                                 anisette: [String: String]) async throws -> Data {
        let result = try await request(endpoint: "ios/downloadTeamProvisioningProfile.action", authentication: authentication,
                                       anisette: anisette, team: team, parameters: ["appIdId": appID])
        guard let profile = result["provisioningProfile"] as? [String: Any],
              let bytes = profile["encodedProfile"] as? Data, !bytes.isEmpty else { throw AppleProvisioningError.missingProfile }
        return bytes
    }
}
private final class AppleRenewalNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
