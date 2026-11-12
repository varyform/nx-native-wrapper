import Foundation

/// Picking what Free Up Space deletes: by file, by game or by kind, with a game's build and its game files never
/// together.
extension Cleanup {
    /// Why a file can't join the selection as it is: a game's build and its game files never go together, since
    /// without both nothing could play or build it again. Converted NSPs can go with the build: the next build
    /// converts the NSZ again.
    public func conflict(_ file: CleanupFile) -> String? {
        guard !selection.contains(file.url),
            let group = groups.first(where: { $0.files.contains(file) })
        else { return nil }
        let selected = group.files.filter { selection.contains($0.url) }
        switch file.role {
        case .original where selected.contains { $0.role == .build }:
            return "Its build is selected: these files are needed to build it again."
        case .build where selected.contains { $0.role == .original }:
            return "Its game files are selected: the build is how it plays without them."
        case .shaderCache where selected.contains { $0.role == .build }:
            return "Goes with its build, which is selected."
        default:
            return nil
        }
    }

    public func isAvailable(_ file: CleanupFile) -> Bool {
        file.blocked == nil && conflict(file) == nil
    }

    /// true: all of its files that can be picked, false: none, nil: some.
    public func isSelected(_ files: [CleanupFile]) -> Bool? {
        let candidates = files.filter { selection.contains($0.url) || isAvailable($0) }
        let count = candidates.filter { selection.contains($0.url) }.count
        return count == 0 ? false : count == candidates.count ? true : nil
    }

    public func isSelected(_ group: CleanupGroup) -> Bool? { isSelected(group.files) }
    public func isSelected(_ kind: CleanupKind) -> Bool? { isSelected(files(kind)) }

    /// Selects every file of them that can be picked, or none when all are selected. One at a time, builds first: a
    /// game picked whole keeps its game files, so it can be built again.
    public func toggle(_ files: [CleanupFile]) {
        if isSelected(files) == true {
            selection.subtract(files.map(\.url))
            return
        }
        for file in files.sorted(by: { ($0.role == .build ? 0 : 1) < ($1.role == .build ? 0 : 1) })
        where isAvailable(file) {
            selection.insert(file.url)
            // the build takes its shader cache with it
            if file.role == .build, let group = groups.first(where: { $0.files.contains(file) }) {
                selection.subtract(group.files.filter { $0.role == .shaderCache }.map(\.url))
            }
        }
    }

    public func toggle(_ group: CleanupGroup) { toggle(group.files) }
    public func toggle(_ kind: CleanupKind) { toggle(files(kind)) }
    public func toggle(_ file: CleanupFile) { toggle([file]) }
}
