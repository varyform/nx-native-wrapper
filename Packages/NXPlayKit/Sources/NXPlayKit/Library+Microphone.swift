import AVFoundation

/// A game's Microphone setting (nxnative's DM_MIC, PR #1822): the game's host or its Mac app's launcher hears the
/// microphone, and macOS asks the app that started them, NX Play. nxnative's docs/frontends.md asks such a front end
/// to get the player's consent itself; without it the game starts with the microphone off.
extension Library {
    /// The setting is on for this play (a toggle's off is "0").
    static func wantsMicrophone(_ environment: [String: String]) -> Bool {
        guard let mic = environment["DM_MIC"] else { return false }
        return !mic.isEmpty && mic != "0"
    }

    /// Asks once; afterwards macOS remembers the answer, and the log says what a refusal means.
    func askForMicrophone(_ job: Job) async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
        default: break
        }
        job.note(
            "microphone: NX Play may not use it, so the game can't hear you. Allow NX Play in System Settings › "
                + "Privacy & Security › Microphone, then play again.")
    }
}
