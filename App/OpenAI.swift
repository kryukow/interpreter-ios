import Foundation
import CryptoKit
import Security
import Darwin

struct ModelChoice: Identifiable { let id: String; let name: String }

enum OpenAI {
    static func json(_ url: String, method: String = "GET", token: String? = nil, body: Data? = nil, contentType: String = "application/json") async throws -> [String: Any] {
        guard let endpoint = URL(string: url), endpoint.scheme == "https",
              ["auth.openai.com", "api.openai.com"].contains(endpoint.host ?? "") else { throw Failure.message("Недопустимый адрес запроса.") }
        var request = URLRequest(url: endpoint); request.httpMethod = method; request.timeoutInterval = 90
        request.httpBody = body; request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw Failure.message("OpenAI HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0). Проверь доступ и лимиты подписки.")
        }
        if data.isEmpty { return [:] }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.message("Некорректный ответ OpenAI.") }; return result
    }
    static func form(_ fields: [String: String]) -> Data {
        var c = URLComponents(); c.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }
    static func refresh(_ old: Session) async throws -> Session {
        guard let current = try SessionStore.load(), current.client == old.client, current.subject == old.subject else { throw Failure.message("Войди в Interpreter заново.") }
        if current.expires > Date().addingTimeInterval(60) { return current }
        guard let refresh = current.refreshToken else { throw Failure.message("Открой Interpreter и войди снова.") }
        let j = try await json("https://auth.openai.com/api/accounts/oauth/token", method: "POST", body: form(["grant_type":"refresh_token", "client_id":old.client,"refresh_token":refresh,"resource":"https://api.openai.com/v1"]),contentType:"application/x-www-form-urlencoded")
        guard let token = j["access_token"] as? String else { throw Failure.message("Не удалось продлить вход.") }
        if let scope = j["scope"] as? String, !scope.split(separator: " ").contains("chatgpt.tokens.use.direct") { throw Failure.message("Нет разрешения использовать Plus.") }
        let next = Session(client: current.client, subject: current.subject, email: current.email, accessToken: token, refreshToken: j["refresh_token"] as? String ?? current.refreshToken, expires: Date().addingTimeInterval(j["expires_in"] as? Double ?? 3600))
        try SessionStore.save(next); return next
    }
    static func models(_ session: Session) async throws -> [ModelChoice] {
        let j = try await json("https://api.openai.com/v1/models",token:session.accessToken)
        return (j["models"] as? [[String:Any]] ?? []).compactMap { m in
            guard m["visibility"] as? String == "list", let id = m["slug"] as? String else { return nil }
            return ModelChoice(id:id,name:m["display_name"] as? String ?? id)
        }
    }
    static func validateIdentity(_ jwt:String, client:String,nonce:String) async throws -> [String:Any] {
        let parts=jwt.split(separator:".").map(String.init)
        guard parts.count==3,let header=try JSONSerialization.jsonObject(with:decode(parts[0])) as? [String:Any],let payload=try JSONSerialization.jsonObject(with:decode(parts[1])) as? [String:Any],header["alg"] as? String=="RS256" else {throw Failure.message("Недопустимый ID token.")}
        let jwks=try await json("https://auth.openai.com/.well-known/jwks.json")
        guard let jwk=(jwks["keys"] as? [[String:Any]])?.first(where:{($0["kid"] as? String)==(header["kid"] as? String) && ($0["kty"] as? String)=="RSA"}),let n=jwk["n"] as? String,let e=jwk["e"] as? String else {throw Failure.message("Не найден ключ проверки входа.")}
        let modulus=try decode(n), exponent=try decode(e)
        guard !modulus.isEmpty,!exponent.isEmpty else{throw Failure.message("Некорректный ключ проверки входа.")}
        let rsa=sequence(integer(modulus)+integer(exponent))
        var error: Unmanaged<CFError>?
        guard let key=SecKeyCreateWithData(rsa as CFData,[kSecAttrKeyType:kSecAttrKeyTypeRSA,kSecAttrKeyClass:kSecAttrKeyClassPublic] as CFDictionary,&error),SecKeyVerifySignature(key,.rsaSignatureMessagePKCS1v15SHA256,Data((parts[0]+"."+parts[1]).utf8) as CFData,try decode(parts[2]) as CFData,&error) else {throw Failure.message("Подпись входа не прошла проверку.")}
        let audiences=payload["aud"] as? [String] ?? [payload["aud"] as? String ?? ""]
        guard payload["iss"] as? String=="https://auth.openai.com",audiences.contains(client),payload["nonce"] as? String==nonce,let exp=payload["exp"] as? Double,exp>Date().timeIntervalSince1970-5,let iat=payload["iat"] as? Double,iat<Date().timeIntervalSince1970+5,let sub=payload["sub"] as? String,!sub.isEmpty else {throw Failure.message("Данные входа не прошли проверку.")}
        return payload
    }
    static func decode(_ s:String) throws -> Data {
        var v=s.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/");v += String(repeating:"=",count:(4-v.count%4)%4)
        guard let data=Data(base64Encoded:v) else {throw Failure.message("Некорректные данные входа.")};return data
    }
    static func length(_ n:Int)->Data{if n<128{return Data([UInt8(n)])};var v=n,b:[UInt8]=[];while v>0{b.insert(UInt8(v&255),at:0);v >>= 8};return Data([0x80|UInt8(b.count)]+b)}
    static func integer(_ data:Data)->Data{var b=data;while b.count>1&&b.first==0{b.removeFirst()};if b.first!&0x80 != 0{b.insert(0,at:0)};return Data([2])+length(b.count)+b}
    static func sequence(_ data:Data)->Data{Data([0x30])+length(data.count)+data}
}

