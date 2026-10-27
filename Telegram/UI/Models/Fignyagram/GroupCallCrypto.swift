import Foundation
import TDLibKit

/// Synchronous trampoline over TDLib's asynchronous group-call media crypto.
/// The tgcalls engine calls its encryption callback synchronously, so the
/// request is issued on a detached task and the engine thread waits for the
/// result.
final class GroupCallCrypto {
    static let shared = GroupCallCrypto()

    func transform(data: Data, ssrc: Int64, encrypt: Bool, channel: Int32, groupCallId: Int32) -> Data? {
        guard let client = TelegramClient.shared.tdClient else { return nil }
        let channelEnum: GroupCallDataChannel = channel == 1
            ? .groupCallDataChannelScreenSharing
            : .groupCallDataChannelMain
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task.detached(priority: .userInitiated) {
            do {
                if encrypt {
                    let result = try await client.encryptGroupCallData(
                        data: data,
                        dataChannel: channelEnum,
                        groupCallId: Int(groupCallId),
                        unencryptedPrefixSize: 0)
                    box.data = result.data
                } else {
                    let result = try await client.decryptGroupCallData(
                        data: data,
                        dataChannel: channelEnum,
                        groupCallId: Int(groupCallId),
                        participantId: nil)
                    box.data = result.data
                }
            } catch {
                CallDiag.log("group crypto failed \(error)")
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 2) == .timedOut {
            CallDiag.log("group crypto timeout")
            return nil
        }
        return box.data
    }

    private final class ResultBox: @unchecked Sendable {
        var data: Data?
    }
}
