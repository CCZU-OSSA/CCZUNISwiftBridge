import Foundation

/// SSO登录连接类型
public enum SSOLoginConnectType: String, Sendable {
    case webvpn = "WEBVPN"
    case common = "COMMON"
}

/// SSO统一登录协议
public protocol SSOLogin {
    func ssoUniversalLogin() async throws -> ElinkLoginInfo?
    func ssoServiceLogin(service: String) async throws -> (Data, HTTPURLResponse)
}

extension DefaultHTTPClient: SSOLogin {
    public func ssoUniversalLogin() async throws -> ElinkLoginInfo? {
        guard let url = URL(string: CCZUConstants.rootSSOLogin) else {
            throw CCZUError.unknown("Invalid URL")
        }
        let (_, response) = try await get(url: url)
        if response.statusCode == 302 {
            return try await handleWebVPNLogin(from: response)
        } else if response.statusCode == 200 {
            _ = try await ssoServiceLogin(service: "")
            await properties.set("SSOLoginConnectType", value: .string(SSOLoginConnectType.common.rawValue))
            return nil
        }
        throw CCZUError.loginFailed("Unexpected status code: \(response.statusCode)")
    }
    
    private func handleWebVPNLogin(from response: HTTPURLResponse) async throws -> ElinkLoginInfo? {
        guard let location = response.value(forHTTPHeaderField: "Location"), let redirectURL = URL(string: location) else {
            throw CCZUError.ssoLoginFailed("缺少重定向地址")
        }
        let (pageData, _) = try await recursionRedirectHandle(url: redirectURL)
        guard let html = String(data: pageData, encoding: .utf8) else {
            throw CCZUError.invalidResponse
        }
        var form = parseHiddenValues(from: html)
        form["username"] = account.username
        form["password"] = Data(account.password.utf8).base64EncodedString()
        let (_, loginResponse) = try await postForm(url: redirectURL, form: form)
        guard let loginLocation = loginResponse.value(forHTTPHeaderField: "Location"), let loginRedirectURL = URL(string: loginLocation) else {
            throw CCZUError.invalidCredentials
        }
        var headers = CCZUConstants.defaultHeaders
        headers["Referer"] = CCZUConstants.rootVPNURL
        let _ = try await get(url: loginRedirectURL, headers: headers)
        if let cookies = HTTPCookieStorage.shared.cookies(for: loginRedirectURL), let clientInfoCookie = cookies.first(where: { $0.name == "clientInfo" }), let decodedData = Data(base64Encoded: clientInfoCookie.value), let jsonString = String(data: decodedData, encoding: .utf8) {
            let decoder = JSONDecoder()
            let loginInfo = try decoder.decode(ElinkLoginInfo.self, from: jsonString.data(using: .utf8)!)
            await properties.set("SSOLoginConnectType", value: .string(SSOLoginConnectType.webvpn.rawValue))
            return loginInfo
        }
        throw CCZUError.ssoLoginFailed("无法提取登录信息")
    }
    
    public func ssoServiceLogin(service: String) async throws -> (Data, HTTPURLResponse) {
        let urlString = service.isEmpty ? CCZUConstants.rootSSOLogin : "\(CCZUConstants.rootSSOLogin)?service=\(service)"
        guard let url = URL(string: urlString) else {
            throw CCZUError.unknown("无效的URL")
        }
        let (data, response) = try await get(url: url)
        if response.statusCode == 302 {
            if let location = response.value(forHTTPHeaderField: "Location"), let redirectURL = URL(string: location) {
                return try await recursionRedirectHandle(url: redirectURL)
            }
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw CCZUError.invalidResponse
        }
        var loginParam = parseHiddenValues(from: html)
        loginParam["username"] = account.username
        loginParam["password"] = Data(account.password.utf8).base64EncodedString()
        let (_, loginResponse) = try await postForm(url: url, form: loginParam)
        if loginResponse.statusCode == 302, let location = loginResponse.value(forHTTPHeaderField: "Location"), let redirectURL = URL(string: location) {
            return try await recursionRedirectHandle(url: redirectURL)
        }
        if loginResponse.statusCode == 200 {
            if let responseHtml = String(data: data, encoding: .utf8), responseHtml.contains("用户名不存在") || responseHtml.contains("密码错误") || responseHtml.contains("用户名或密码错误") {
                throw CCZUError.invalidCredentials
            }
            return (Data(), loginResponse)
        }
        throw CCZUError.ssoLoginFailed("SSO服务登录失败")
    }
    
    private func recursionRedirectHandle(url: URL, depth: Int = 0) async throws -> (Data, HTTPURLResponse) {
        guard depth < 10 else { throw CCZUError.unknown("Too many redirects") }
        let (data, response) = try await get(url: url)
        if response.statusCode == 302, let location = response.value(forHTTPHeaderField: "Location") {
            let nextURL: URL
            if location.hasPrefix("http") {
                guard let url = URL(string: location) else { throw CCZUError.unknown("Invalid redirect URL") }
                nextURL = url
            } else {
                guard let url = URL(string: location, relativeTo: url) else { throw CCZUError.unknown("Invalid relative redirect URL") }
                nextURL = url
            }
            return try await recursionRedirectHandle(url: nextURL, depth: depth + 1)
        }
        return (data, response)
    }
    
    private func parseHiddenValues(from html: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = #"<input[^>]*type\s*=\s*["']hidden["'][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return result }
        let nsString = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsString.length))
        for match in matches {
            let matchString = nsString.substring(with: match.range)
            if let name = extractAttribute("name", from: matchString), let value = extractAttribute("value", from: matchString) {
                result[name] = value
            }
        }
        return result
    }
    
    private func extractAttribute(_ attribute: String, from html: String) -> String? {
        let pattern = #"\#(attribute)\s*=\s*["']([^"']*)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let nsString = html as NSString
        if let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: nsString.length)) {
            if match.numberOfRanges > 1 {
                return nsString.substring(with: match.range(at: 1))
            }
        }
        return nil
    }
}
