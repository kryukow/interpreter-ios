import Foundation
import Combine
import Network
import CryptoKit
import Security

final class LoopbackCallback {
    private var listener: NWListener?
    private let queue = DispatchQueue(label:"Interpreter.login")
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:.ipv4(.loopback),port:.any)
        let listener = try NWListener(using:parameters); self.listener=listener
        return try await withCheckedThrowingContinuation { continuation in
            var delivered=false
            listener.stateUpdateHandler = { state in
                if delivered{return}
                if case .ready=state,let port=listener.port {delivered=true;continuation.resume(returning:port.rawValue)}
                if case .failed(let error)=state {delivered=true;continuation.resume(throwing:error)}
            }
            listener.newConnectionHandler={connection in connection.cancel()}
            listener.start(queue:self.queue)
        }
    }
    func wait(state:String,port:UInt16) async throws -> URL {
        guard let listener else {throw Failure.message("Вход не запущен.")}
        return try await withCheckedThrowingContinuation { continuation in
            var delivered=false
            let timeout=DispatchWorkItem {
                if !delivered{delivered=true;listener.cancel();continuation.resume(throwing:Failure.message("Время входа истекло. Попробуй снова."))}
            }
            queue.asyncAfter(deadline:.now()+600,execute:timeout)
            listener.newConnectionHandler={connection in
                connection.start(queue:self.queue)
                self.receive(connection,buffer:Data(),port:port){url in
                    guard !delivered,URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name=="state"})?.value==state else{return false}
                    delivered=true;timeout.cancel();continuation.resume(returning:url);return true
                }
            }
        }
    }
    private func receive(_ connection:NWConnection,buffer:Data,port:UInt16,accept:@escaping(URL)->Bool){
        connection.receive(minimumIncompleteLength:1,maximumLength:8192){data,_,done,error in
            let all=buffer+(data ?? Data())
            guard all.count<=16384,error==nil else{connection.cancel();return}
            guard let request=String(data:all,encoding:.utf8),request.contains("\r\n\r\n") else{
                if done{connection.cancel()}else{self.receive(connection,buffer:all,port:port,accept:accept)};return
            }
            let first=request.components(separatedBy:"\r\n")[0].split(separator:" ")
            guard first.count==3,first[0]=="GET",first[1].hasPrefix("/auth/callback?"),let url=URL(string:"http://127.0.0.1:\(port)"+first[1]),accept(url) else{connection.cancel();return}
            let html="<!doctype html><meta charset=utf-8><p>Вход получен. Вернись в Interpreter.</p>"
            let response="HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(html.utf8.count)\r\n\r\n"+html
            connection.send(content:Data(response.utf8),completion:.contentProcessed{_ in connection.cancel()})
        }
    }
    func stop(){listener?.cancel();listener=nil}
    deinit{stop()}
}

@MainActor final class Login: ObservableObject {
    @Published var browserURL: URL?
    @Published var message=""
    private var callback:LoopbackCallback?
    static func random() throws -> String {
        var bytes=[UInt8](repeating:0,count:32)
        guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes)==errSecSuccess else {throw Failure.message("Не удалось создать защищённый вход.")}
        return Data(bytes).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
    }
    func signIn() async throws {
        let d=try SessionStore.defaults(),host=try SessionStore.host()
        let originalClient=d.string(forKey:"client") ?? "dynamic_agent_client"
        let state=try Self.random(),nonce=try Self.random(),verifier=try Self.random()
        let server=LoopbackCallback();callback=server;defer{server.stop();callback=nil;browserURL=nil}
        let port=try await server.start(),redirect="http://127.0.0.1:\(port)/auth/callback"
        let challenge=Data(SHA256.hash(data:Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
        var fields=["client_id":originalClient,"ext_agent_host_id":host,"response_type":"code","redirect_uri":redirect,"scope":"openid profile email offline_access resource.invoke chatgpt.tokens.use.direct","resource":"https://api.openai.com/v1","state":state,"nonce":nonce,"code_challenge_method":"S256","code_challenge":challenge]
        if originalClient=="dynamic_agent_client"{fields["agent_name_hint"]="Interpreter iPhone"}
        var c=URLComponents(string:"https://auth.openai.com/api/accounts/authorize")!;c.queryItems=fields.map{URLQueryItem(name:$0.key,value:$0.value)}
        message="Войди через официальную страницу ChatGPT."
        // Register the callback receiver before presenting Safari.
        let waiting=Task{try await server.wait(state:state,port:port)}
        await Task.yield();browserURL=c.url
        let result=try await waiting.value
        browserURL=nil
        let items=URLComponents(url:result,resolvingAgainstBaseURL:false)?.queryItems ?? []
        func value(_ name:String)->String?{items.first(where:{$0.name==name})?.value}
        if let error=value("error"){throw Failure.message("Вход отклонён: "+error)}
        let client=value("client_id") ?? originalClient
        guard let code=value("code"),client != "dynamic_agent_client",(originalClient=="dynamic_agent_client"||originalClient==client) else{throw Failure.message("Неполная регистрация ChatGPT.")}
        let tokens=try await OpenAI.json("https://auth.openai.com/api/accounts/oauth/token",method:"POST",body:OpenAI.form(["grant_type":"authorization_code","client_id":client,"code":code,"code_verifier":verifier,"redirect_uri":redirect,"resource":"https://api.openai.com/v1"]),contentType:"application/x-www-form-urlencoded")
        guard let jwt=tokens["id_token"] as? String,let access=tokens["access_token"] as? String,(tokens["scope"] as? String ?? "").split(separator:" ").contains("chatgpt.tokens.use.direct") else{throw Failure.message("Нет разрешения использовать подписку ChatGPT.")}
        let identity=try await OpenAI.validateIdentity(jwt,client:client,nonce:nonce)
        if let savedSubject=d.string(forKey:"subject"),originalClient==client,savedSubject != identity["sub"] as? String{throw Failure.message("Аккаунт регистрации изменился.")}
        let session=Session(client:client,subject:identity["sub"] as! String,email:identity["email"] as? String ?? "ChatGPT",accessToken:access,refreshToken:tokens["refresh_token"] as? String,expires:Date().addingTimeInterval(tokens["expires_in"] as? Double ?? 3600))
        try SessionStore.save(session);d.set(client,forKey:"client");d.set(session.subject,forKey:"subject")
        message="Подключено."
    }
}

