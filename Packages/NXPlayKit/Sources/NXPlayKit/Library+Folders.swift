import AppKit
import Foundation

/// The games folders: one library from several folders, each a folder of games (one subfolder per game) or a single
/// game's own folder. Builds and saves stay in each game's folder, so a game added through another folder plays on
/// from its build. A folder inside another one, or holding one, is refused: its games would show twice.
extension Library {
    /// Add Folder…: the picker, then the folder unless it overlaps one already there.
    public func addRoot() {
        guard let url = PathPicker.choose(directory: true, startingAt: roots.last?.path) else { return }
        if let problem = addRoot(url) { self.problem = problem }
    }

    /// The folder added, or why it isn't.
    @discardableResult
    func addRoot(_ url: URL) -> String? {
        let folder = url.standardizedFileURL
        if let other = roots.first(where: { Self.overlap(folder, $0.standardizedFileURL) }) {
            let shown = (other.path as NSString).abbreviatingWithTildeInPath
            return folder.path.lowercased() == other.standardizedFileURL.path.lowercased()
                ? "\(shown) is already a games folder."
                : "\((folder.path as NSString).abbreviatingWithTildeInPath) overlaps \(shown), a games folder already: one folder can't be inside another, or their games would show twice."
        }
        roots.append(folder)
        return nil
    }

    /// The folder's games leave the library; nothing on disk changes.
    public func removeRoot(_ url: URL) {
        roots.removeAll { $0 == url }
        if let selection, !games.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    /// A folder whose disk isn't connected (or that was moved): kept, its games back once it is there.
    public func isConnected(_ root: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &directory) && directory.boolValue
    }

    /// The same folder, or one inside the other; without regard to case, as the Mac's volumes are by default.
    static func overlap(_ a: URL, _ b: URL) -> Bool {
        let a = (a.path.hasSuffix("/") ? a.path : a.path + "/").lowercased()
        let b = (b.path.hasSuffix("/") ? b.path : b.path + "/").lowercased()
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    /// A disk mounted or ejected may hold a games folder.
    func observeVolumes() {
        let center = NSWorkspace.shared.notificationCenter
        volumeObservers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map {
            center.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.roots.isEmpty else { return }
                    self.refresh()
                }
            }
        }
    }
}
