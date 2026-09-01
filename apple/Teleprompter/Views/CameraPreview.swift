import AVFoundation
import SwiftUI

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// La imagen de la cámara con detección de códigos QR.
///
/// La sesión de captura se monta y se desmonta con la vista, y corre en su
/// propia cola: `startRunning` bloquea, y hacerlo en la principal congela la
/// interfaz justo cuando se está abriendo la pantalla.
struct CameraPreview {
    /// Se llama en la cola principal con el contenido de cada código leído.
    let onCode: (String) -> Void

    @MainActor
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    @MainActor
    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let session = AVCaptureSession()
        /// Solo para arrancar y parar: `startRunning` bloquea, y hacerlo en la
        /// principal congela la interfaz al abrir la pantalla.
        private let queue = DispatchQueue(label: "qr.capture")
        private let onCode: (String) -> Void

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
            super.init()
            configure()
        }

        private func configure() {
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            guard
                let device = AVCaptureDevice.default(
                    .builtInWideAngleCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: device),
                session.canAddInput(input)
            else { return }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            // El delegado va en la cola principal a propósito: son unos pocos
            // códigos por segundo y así el resultado no tiene que cruzar de
            // cola para llegar a la interfaz.
            output.setMetadataObjectsDelegate(self, queue: .main)
            // Los tipos válidos solo se pueden pedir DESPUÉS de añadir la
            // salida a la sesión; antes, la lista está vacía y esto revienta.
            if output.availableMetadataObjectTypes.contains(.qr) {
                output.metadataObjectTypes = [.qr]
            }
        }

        func start() {
            guard !session.isRunning else { return }
            queue.async { [session] in session.startRunning() }
        }

        func stop() {
            guard session.isRunning else { return }
            queue.async { [session] in session.stopRunning() }
        }

        nonisolated func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput objects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            let codes = objects
                .compactMap { $0 as? AVMetadataMachineReadableCodeObject }
                .compactMap(\.stringValue)
            guard let code = codes.first else { return }
            MainActor.assumeIsolated { onCode(code) }
        }
    }
}

#if os(iOS)
    extension CameraPreview: UIViewRepresentable {
        func makeUIView(context: Context) -> PreviewView {
            let view = PreviewView()
            view.backgroundColor = .black
            view.videoLayer.session = context.coordinator.session
            view.videoLayer.videoGravity = .resizeAspectFill
            context.coordinator.start()
            return view
        }

        func updateUIView(_ view: PreviewView, context: Context) {}

        static func dismantleUIView(_ view: PreviewView, coordinator: Coordinator) {
            coordinator.stop()
        }
    }

    /// La capa de vídeo como capa de respaldo de la vista: así se redimensiona
    /// sola con ella, sin tener que seguir el tamaño a mano.
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
#else
    extension CameraPreview: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.black.cgColor

            let preview = AVCaptureVideoPreviewLayer(session: context.coordinator.session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            view.layer?.addSublayer(preview)

            context.coordinator.start()
            return view
        }

        func updateNSView(_ view: NSView, context: Context) {}

        static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
            coordinator.stop()
        }
    }
#endif
