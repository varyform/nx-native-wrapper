import Foundation

struct PendingPairing: Identifiable {
    let id = UUID()
    let link: PairingLink
}

// Confirmation waits for the scanner's dismissal so the two sheets never compete.
struct PairingPresentation {
    var pending: PendingPairing?
    var showsScanner = false {
        didSet {
            if showsScanner && !oldValue {
                scannerID = UUID()
                scannerIsPresented = true
                scanned = nil
            }
        }
    }
    private(set) var scannerID = UUID()
    private var scannerIsPresented = false
    private var scanned: PairingLink?

    var isPresented: Bool { scannerIsPresented || pending != nil }

    mutating func open(_ link: PairingLink) {
        scannerID = UUID()
        if scannerIsPresented {
            scanned = link
            showsScanner = false
        } else {
            pending = PendingPairing(link: link)
        }
    }

    mutating func receiveScan(_ link: PairingLink, from id: UUID) {
        guard scannerIsPresented, showsScanner, id == scannerID else { return }
        scanned = link
        showsScanner = false
    }

    mutating func scannerDidDismiss() {
        scannerIsPresented = false
        showsScanner = false
        scannerID = UUID()
        if let scanned { pending = PendingPairing(link: scanned) }
        scanned = nil
    }
}
