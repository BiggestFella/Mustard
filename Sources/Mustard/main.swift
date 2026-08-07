import Foundation
import MustardKit

if CommandLine.arguments == [CommandLine.arguments[0], "--verify-worker-contract"] {
    do {
        let contract = try AgentTurnContract.workerContract()
        guard contract.contains("# Mustard delegated-task worker contract") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        print("Verified packaged Mustard worker contract")
    } catch {
        FileHandle.standardError.write(Data("Worker contract verification failed: \(error)\n".utf8))
        exit(EXIT_FAILURE)
    }
} else {
    MustardApp.main()
}
