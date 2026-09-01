import SwiftUI

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// Impide que la pantalla se apague. Nadie quiere que el guion se vaya a negro
/// a mitad de una toma porque llevaba dos minutos sin tocar nada.
///
/// Es el equivalente nativo del bloqueo de pantalla del navegador, sin el baile
/// de reintentos que hacía falta en Safari.
private struct WakeLockModifier: ViewModifier {
    let isActive: Bool

    #if os(macOS)
        @State private var activity: NSObjectProtocol?
    #endif

    func body(content: Content) -> some View {
        content
            .onAppear { apply(isActive) }
            .onDisappear { apply(false) }
            .onChange(of: isActive) { _, value in apply(value) }
    }

    private func apply(_ active: Bool) {
        #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = active
        #else
            if active, activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                    reason: "Teleprompter en marcha"
                )
            } else if !active, let current = activity {
                ProcessInfo.processInfo.endActivity(current)
                activity = nil
            }
        #endif
    }
}

extension View {
    func wakeLock(_ isActive: Bool) -> some View {
        modifier(WakeLockModifier(isActive: isActive))
    }
}
