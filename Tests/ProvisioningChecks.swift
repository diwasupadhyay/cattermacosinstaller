import Foundation
@main struct ProvisioningChecks {
    static func main() async throws {
        let auth = AppleRenewalSession(accountID: "synthetic-account", token: "synthetic-token")
        let headers = ["X-Apple-I-MD": "synthetic", "X-Apple-I-MD-M": "synthetic"]
        let request = try AppleProvisioningClient.request(endpoint: "listTeams.action", authentication: auth, anisette: headers, team: nil)
        precondition(request.url?.host == "developerservices2.apple.com")
        precondition(request.url?.query == "clientId=XABBG36SBA")
        precondition(!request.url!.absoluteString.contains(auth.token))
        precondition(request.value(forHTTPHeaderField: "X-Apple-GS-Token") == auth.token)
        for endpoint in ["https://evil.example/", "ios/revokeDevelopmentCert.action", "../other"] {
            do { _ = try AppleProvisioningClient.request(endpoint: endpoint, authentication: auth, anisette: headers, team: nil); preconditionFailure() }
            catch { precondition(error as? AppleProvisioningError == .invalidIdentifier) }
        }
        var injected = headers; injected["Host"] = "evil.example"
        do { _ = try AppleProvisioningClient.request(endpoint: "listTeams.action", authentication: auth, anisette: injected, team: nil); preconditionFailure() }
        catch { precondition(error as? AppleProvisioningError == .invalidHeaders) }
        let client = AppleProvisioningClient { req in
            let body = try PropertyListSerialization.propertyList(from: req.httpBody!, options: [], format: nil) as! [String: Any]
            precondition(body["teamId"] as? String == "TEAM")
            precondition(body["appIdId"] as? String == "EXISTING")
            let data = try PropertyListSerialization.data(fromPropertyList: ["resultCode": 0, "provisioningProfile": ["encodedProfile": Data("synthetic-profile".utf8)]], format: .xml, options: 0)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let result = try await client.downloadExistingProfile(team: "TEAM", appID: "EXISTING", authentication: auth, anisette: headers)
        precondition(result == Data("synthetic-profile".utf8))
        for status in [302, 401, 503] {
            let client = AppleProvisioningClient { req in (Data(), HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!) }
            do { _ = try await client.downloadExistingProfile(team: "TEAM", appID: "EXISTING", authentication: auth, anisette: headers); preconditionFailure() }
            catch { precondition(error as? AppleProvisioningError == .rejectedHTTP(status)) }
        }
        let cases: [(Data, AppleProvisioningError)] = [
            (Data("not a plist".utf8), .malformedResponse),
            (try PropertyListSerialization.data(fromPropertyList: ["resultCode": 7460], format: .xml, options: 0), .rejectedResult(7460)),
            (try PropertyListSerialization.data(fromPropertyList: ["resultCode": 0], format: .xml, options: 0), .missingProfile),
            (Data(repeating: 0, count: 4 * 1024 * 1024 + 1), .responseTooLarge)
        ]
        for (data, expected) in cases {
            let client = AppleProvisioningClient { req in (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
            do { _ = try await client.downloadExistingProfile(team: "TEAM", appID: "EXISTING", authentication: auth, anisette: headers); preconditionFailure() }
            catch { precondition(error as? AppleProvisioningError == expected) }
        }
        print("Native provisioning request, endpoint/header isolation and profile download checks passed (synthetic transport; no Apple account used).")
    }
}
