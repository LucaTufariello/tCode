import Darwin
import Foundation
import TCodeCore
import TCodeSyntax
import os

final class SyntaxWorker: NSObject, SyntaxServiceProtocol {
  private let queue = DispatchQueue(label: "dev.tufariello.tCode.syntax", qos: .userInitiated)
  private var parser: NativeSyntaxParser?
  private let logger = Logger(subsystem: "dev.tufariello.tCode.SyntaxService", category: "parsing")
  func highlight(_ request: Data, module: FileHandle?, reply: @escaping (Data?, String?) -> Void) {
    guard request.count <= 80 * 1024 * 1024 else {
      reply(nil, "Request limit exceeded")
      return
    }
    logger.debug("Syntax request received")
    queue.async { [self] in
      do {
        logger.debug("Syntax request processing")
        if parser == nil {
          parser = try NativeSyntaxParser(
            moduleDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
              "Grammars/" + UUID().uuidString))
        }
        let decoded = try JSONDecoder().decode(SyntaxRequest.self, from: request)
        let moduleBytes: Data?
        if let module {
          var status = stat()
          guard fstat(module.fileDescriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG, status.st_size >= 32, status.st_size <= 67_108_864
          else {
            throw SyntaxFailure.invalidGrammar("Invalid grammar file descriptor")
          }
          moduleBytes = try module.readToEnd()
        } else {
          moduleBytes = nil
        }
        let loaded = SyntaxRequest(
          documentID: decoded.documentID, version: decoded.version, text: decoded.text,
          grammar: decoded.grammar, moduleData: moduleBytes, queryData: decoded.queryData)
        logger.debug("Syntax parser initialized")
        let result = try parser!.highlight(loaded, moduleFileDescriptor: module?.fileDescriptor)
        logger.debug("Syntax request complete")
        reply(try JSONEncoder().encode(result), nil)
      } catch {
        logger.error("Syntax request failed: \(error.localizedDescription, privacy: .public)")
        reply(nil, error.localizedDescription)
      }
    }
  }
  func closeDocument(_ identifier: String) {
    guard let id = UUID(uuidString: identifier) else { return }
    queue.async { [self] in parser?.close(id) }
  }
  func isolationProbe(_ forbiddenPath: String, reply: @escaping (Bool, Bool, Int32) -> Void) {
    queue.async {
      let canRead = (try? Data(contentsOf: URL(fileURLWithPath: forbiddenPath))) != nil
      // A direct IP requires no DNS permission and tests the actual outbound socket restriction.
      let socketFD = socket(AF_INET, SOCK_STREAM, 0)
      var destination = sockaddr_in()
      destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      destination.sin_family = sa_family_t(AF_INET)
      destination.sin_port = in_port_t(443).bigEndian
      _ = inet_pton(AF_INET, "1.1.1.1", &destination.sin_addr)
      _ = fcntl(socketFD, F_SETFL, O_NONBLOCK)
      let connection = withUnsafePointer(to: &destination) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      let failure = errno
      if socketFD >= 0 { Darwin.close(socketFD) }
      reply(canRead, connection == 0 || failure == EINPROGRESS, failure)
    }
  }
  func terminateForTesting() { exit(77) }
}
final class Listener: NSObject, NSXPCListenerDelegate {
  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
    -> Bool
  {
    connection.exportedInterface = NSXPCInterface(with: SyntaxServiceProtocol.self)
    connection.exportedObject = SyntaxWorker()
    connection.resume()
    return true
  }
}
let delegate = Listener()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
