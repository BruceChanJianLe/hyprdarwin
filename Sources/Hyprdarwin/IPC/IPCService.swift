import Foundation
import HyprdarwinIPC

/// hyprdarwin's two sockets, hyprctl-style:
/// `$TMPDIR/hyprdarwin/<signature>/.socket.sock` answers requests
/// (hyprdarwinctl) and `.socket2.sock` streams `EVENT>>DATA` lines. The
/// signature is exported as HYPRDARWIN_INSTANCE_SIGNATURE to every process
/// hyprdarwin starts. Socket I/O runs on background queues; requests are
/// handed to `onRequest` on the main thread.
final class IPCService {
    /// Answer on the main thread by calling the reply closure once.
    var onRequest: ((IPCRequest, @escaping (String) -> Void) -> Void)?

    let instance = IPCInstance(signature: IPCPaths.newSignature(), base: IPCPaths.defaultBase)
    private var requests: RequestServer?
    private var events: EventServer?

    func start() {
        let base = (instance.directory as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            IPCPaths.removeStaleInstances(base: base)
            try FileManager.default.createDirectory(atPath: instance.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let requests = RequestServer(path: instance.requestSocket) { [weak self] request, reply in
                guard let self, let onRequest = self.onRequest else {
                    reply(IPCReply.error("hyprdarwin is shutting down"))
                    return
                }
                onRequest(request, reply)
            }
            let events = EventServer(path: instance.eventSocket)
            try requests.start()
            try events.start()
            self.requests = requests
            self.events = events
            setenv(IPCPaths.signatureVariable, instance.signature, 1)
            Log.info("IPC sockets in \(instance.directory) (\(IPCPaths.signatureVariable)=\(instance.signature))")
        } catch {
            Log.error("IPC sockets unavailable, hyprdarwinctl will not reach this instance: \(error)")
            stop()
        }
    }

    func publish(_ lines: [String]) {
        events?.publish(lines)
    }

    func stop() {
        requests?.stop()
        events?.stop()
        requests = nil
        events = nil
        try? FileManager.default.removeItem(atPath: instance.directory)
    }
}
