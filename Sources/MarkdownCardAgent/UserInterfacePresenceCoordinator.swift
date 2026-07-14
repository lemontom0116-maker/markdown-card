import AppKit

@MainActor
final class UserInterfacePresenceCoordinator {
    enum Surface: Hashable {
        case cardLibrary
        case settings
    }

    private var visibleSurfaces: Set<Surface> = []
    private let setActivationPolicy: (NSApplication.ActivationPolicy) -> Void

    init(setActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { policy in
        _ = NSApp.setActivationPolicy(policy)
    }) {
        self.setActivationPolicy = setActivationPolicy
    }

    func willShow(_ surface: Surface) {
        visibleSurfaces.insert(surface)
        setActivationPolicy(.regular)
    }

    func didClose(_ surface: Surface) {
        visibleSurfaces.remove(surface)
        guard visibleSurfaces.isEmpty else { return }
        // Defer the activation-policy transition until AppKit has completed
        // the close transaction, avoiding a transient menu/window flicker.
        DispatchQueue.main.async { [weak self] in
            guard let self, visibleSurfaces.isEmpty else { return }
            setActivationPolicy(.accessory)
        }
    }

    var isPresentingUserInterface: Bool { !visibleSurfaces.isEmpty }
}
