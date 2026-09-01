import PrompterCore
import SwiftUI

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// El guion, dibujado y desplazado a mano.
///
/// Es un `UITextView`/`NSTextView` con TextKit 2 y no un `Text` de SwiftUI por
/// una razón concreta: un guion de 50 KB a 64 puntos mide decenas de miles de
/// puntos de alto. TextKit 2 solo maqueta lo que se ve, y mover el origen del
/// scroll es una traslación pura, no un relayout. Con `Text` cada cambio de
/// cuerpo de letra maquetaría el guion entero de golpe.
///
/// **Los rellenos.** El texto lleva r·alto de hueco por arriba y (1−r)·alto por
/// abajo, donde r es la línea de lectura elegida. Sumen lo que sumen las dos
/// partes por separado, el total es siempre el alto entero, y por eso el
/// recorrido medido es exactamente la altura del texto: (rH + T + (1−r)H) − H =
/// T. Así `position` significa lo mismo en el iPad a pantalla completa que en el
/// panel del móvil, y subir o bajar la línea de lectura no descoloca el guion.
struct PrompterTextView {
    let text: String
    let fontSize: Double
    let lineHeight: Double
    /// Margen horizontal en fracción del ancho (0...0,30).
    let marginFraction: Double
    let engine: ScriptScrollEngine
    /// El hueco, medido por SwiftUI.
    ///
    /// Viene de fuera y no de `bounds` porque en la primera pasada la vista aún
    /// no tiene tamaño, y `updateUIView` no se vuelve a llamar solo porque
    /// aparezca: el guion se quedaba pintado con un hueco de altura cero, o sea
    /// pegado al borde en vez de sobre la línea de lectura.
    let viewportSize: CGSize
    /// Dónde cae la línea de lectura, en fracción del alto del hueco.
    var readLine: Double = Geometry.defaultReadLine

    /// Atributos del guion. Se reconstruyen solo cuando cambia alguno de los
    /// valores discretos, nunca por fotograma.
    func attributedText() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        // El interlineado de la web es un multiplicador del cuerpo; fijar
        // mínimo y máximo al mismo valor lo reproduce.
        paragraph.minimumLineHeight = fontSize * lineHeight
        paragraph.maximumLineHeight = fontSize * lineHeight

        #if os(iOS)
            let font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
            let color = UIColor.white
        #else
            let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
            let color = NSColor.white
        #endif

        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
    }

    @MainActor
    func makeCoordinator() -> Coordinator {
        Coordinator(engine: engine)
    }

    /// Cuánto ocupa el guion entero.
    ///
    /// TextKit 2 solo maqueta lo que se ve, que es justo lo que lo hace rápido
    /// con guiones largos. El efecto secundario es que preguntar por el tamaño
    /// del contenido —o por `usageBoundsForTextContainer`— devuelve solo lo ya
    /// maquetado: con el guion de ejemplo daba 256 puntos de los 427 reales, y
    /// la lectura «terminaba» a media página.
    ///
    /// Recorrer los fragmentos con `ensuresLayout` obliga a maquetarlo entero y
    /// da el fondo de verdad. Es una pasada completa, pero solo se paga al
    /// cambiar el texto, el cuerpo de letra, el interlineado o los márgenes.
    @MainActor
    static func fullHeight(of layoutManager: NSTextLayoutManager?) -> Double? {
        guard let layoutManager else { return nil }
        var bottom: CGFloat = 0
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: [.ensuresLayout, .ensuresExtraLineFragment]
        ) { fragment in
            bottom = max(bottom, fragment.layoutFragmentFrame.maxY)
            return true
        }
        return bottom > 0 ? bottom : nil
    }

    @MainActor
    final class Coordinator {
        let engine: ScriptScrollEngine
        var displayLink: CADisplayLink?
        /// Lo último que se pintó, para no hacer trabajo de más. Nil obliga a
        /// pintar en la siguiente pasada.
        var lastPaintedOffset: Double?
        var lastSignature: String = ""
        var viewportHeight: Double = 0
        /// La línea de lectura vigente. La guarda el coordinador porque el
        /// pintado ocurre fuera de SwiftUI, en cada fotograma.
        var readLine: Double = Geometry.defaultReadLine

        /// ¿Merece la pena mover el origen hasta aquí?
        func shouldPaint(_ offset: Double) -> Bool {
            guard let lastPaintedOffset else { return true }
            return abs(offset - lastPaintedOffset) > 0.01
        }

        init(engine: ScriptScrollEngine) {
            self.engine = engine
        }

        @objc func frame(_ link: CADisplayLink) {
            engine.tick(at: link.timestamp)
        }

        /// El reloj retiene a su objetivo, así que hay que soltarlo a mano
        /// cuando la vista se va; si no, el bucle sigue corriendo para siempre.
        func stop() {
            displayLink?.invalidate()
            displayLink = nil
            engine.onPaint = nil
        }
    }
}

// -------------------------------------------------------------------- iOS

#if os(iOS)
    extension PrompterTextView: UIViewRepresentable {
        func makeUIView(context: Context) -> UITextView {
            let textView = UITextView(usingTextLayoutManager: true)
            assert(
                textView.textLayoutManager != nil,
                "hace falta TextKit 2: tocar `layoutManager` lo degrada a TextKit 1 en silencio")

            textView.isEditable = false
            textView.isSelectable = false
            textView.backgroundColor = .clear
            textView.textContainerInset = .zero
            textView.textContainer.lineFragmentPadding = 0
            // El ancho se fija a mano, no siguiendo al marco de la vista: al
            // medir, SwiftUI todavía no le ha dado su tamaño, y el guion se
            // maquetaba con líneas larguísimas y salía mucho más corto de lo
            // que luego se ve.
            textView.textContainer.widthTracksTextView = false
            textView.contentInsetAdjustmentBehavior = .never
            textView.showsVerticalScrollIndicator = false
            textView.showsHorizontalScrollIndicator = false
            // Se conserva el scroll interno porque es lo que permite mover el
            // origen sin repintar, pero el dedo no lo maneja: los gestos los
            // interpreta la vista de encima.
            textView.panGestureRecognizer.isEnabled = false
            textView.isUserInteractionEnabled = false

            context.coordinator.engine.onPaint = { [weak textView] position in
                guard let textView else { return }
                let coordinator = context.coordinator
                let offset = -coordinator.readLine * coordinator.viewportHeight
                    + position * coordinator.engine.travel
                guard coordinator.shouldPaint(offset) else { return }
                coordinator.lastPaintedOffset = offset
                textView.contentOffset = CGPoint(x: 0, y: offset)
            }

            let link = CADisplayLink(
                target: context.coordinator, selector: #selector(Coordinator.frame))
            // En `.common` para que el guion no se pare mientras alguien
            // arrastra un slider.
            link.add(to: .main, forMode: .common)
            context.coordinator.displayLink = link

            return textView
        }

        func updateUIView(_ textView: UITextView, context: Context) {
            let coordinator = context.coordinator
            let signature = "\(text.count)|\(fontSize)|\(lineHeight)|\(text.hashValue)"
            if signature != coordinator.lastSignature {
                coordinator.lastSignature = signature
                textView.attributedText = attributedText()
            }

            let width = viewportSize.width
            let height = viewportSize.height
            guard width > 0, height > 0 else { return }

            let horizontal = width * marginFraction
            if abs(textView.textContainerInset.left - horizontal) > 0.5 {
                textView.textContainerInset = UIEdgeInsets(
                    top: 0, left: horizontal, bottom: 0, right: horizontal)
            }
            let columnWidth = max(1, width - horizontal * 2)
            if abs(textView.textContainer.size.width - columnWidth) > 0.5 {
                // Alto cero = sin límite: el guion crece lo que haga falta.
                textView.textContainer.size = CGSize(width: columnWidth, height: 0)
            }

            // Los rellenos de arriba y abajo son del hueco, no del texto: por
            // eso van como inset del scroll y no del contenedor de texto.
            let top = height * readLine
            let bottom = height * Geometry.tailPadding(readLine: readLine)
            if abs(textView.contentInset.top - top) > 0.5 {
                textView.contentInset = UIEdgeInsets(
                    top: top, left: 0, bottom: bottom, right: 0)
            }
            coordinator.viewportHeight = height
            if abs(coordinator.readLine - readLine) > 0.0001 {
                coordinator.readLine = readLine
                // La línea ha cambiado de sitio: hay que repintar aunque la
                // posición del guion sea la misma de antes.
                coordinator.lastPaintedOffset = nil
            }

            // Maquetar entero antes de que el scroll calcule su tamaño: si no,
            // el recorrido se queda corto y no deja llegar al final del guion.
            let travel = Self.fullHeight(of: textView.textLayoutManager)
            textView.layoutIfNeeded()
            coordinator.engine.measured(travel: travel ?? textView.contentSize.height)
            // Repintar en el mismo ciclo: si no, un cambio de insets al girar
            // el aparato se ve como un salto.
            coordinator.lastPaintedOffset = nil
            coordinator.engine.onPaint?(coordinator.engine.position)
        }

        static func dismantleUIView(_ textView: UITextView, coordinator: Coordinator) {
            coordinator.stop()
        }
    }
#endif

// ------------------------------------------------------------------ macOS

#if os(macOS)
    /// Un clip que no recorta el recorrido a los bordes del documento.
    ///
    /// Hace falta porque el esquema 40/60 pide colocar el origen fuera del
    /// documento: en la posición 0 el texto empieza al 40 % de la altura, que en
    /// coordenadas de scroll es un origen negativo.
    final class UnconstrainedClipView: NSClipView {
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
            proposedBounds
        }
    }

    extension PrompterTextView: NSViewRepresentable {
        func makeNSView(context: Context) -> NSScrollView {
            let scrollView = NSScrollView()
            scrollView.contentView = UnconstrainedClipView()
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.verticalScrollElasticity = .none
            scrollView.horizontalScrollElasticity = .none

            let textView = NSTextView(usingTextLayoutManager: true)
            assert(
                textView.textLayoutManager != nil,
                "hace falta TextKit 2: tocar `layoutManager` lo degrada a TextKit 1 en silencio")

            textView.isEditable = false
            textView.isSelectable = false
            textView.drawsBackground = false
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.textContainerInset = .zero
            textView.textContainer?.lineFragmentPadding = 0
            textView.textContainer?.widthTracksTextView = true
            textView.autoresizingMask = [.width]

            scrollView.documentView = textView

            context.coordinator.engine.onPaint = { [weak scrollView] position in
                guard let scrollView else { return }
                let coordinator = context.coordinator
                let offset = -coordinator.readLine * coordinator.viewportHeight
                    + position * coordinator.engine.travel
                guard coordinator.shouldPaint(offset) else { return }
                coordinator.lastPaintedOffset = offset
                scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: offset))
            }

            // En el Mac el reloj de fotogramas se pide a la vista, y así sigue
            // la pantalla en la que esté de verdad la ventana: un monitor
            // externo a 60 Hz y el portátil a 120 no van al mismo ritmo.
            let link = scrollView.displayLink(
                target: context.coordinator, selector: #selector(Coordinator.frame))
            link.add(to: .main, forMode: .common)
            context.coordinator.displayLink = link

            return scrollView
        }

        func updateNSView(_ scrollView: NSScrollView, context: Context) {
            guard let textView = scrollView.documentView as? NSTextView else { return }
            let coordinator = context.coordinator

            let signature = "\(text.count)|\(fontSize)|\(lineHeight)|\(text.hashValue)"
            if signature != coordinator.lastSignature {
                coordinator.lastSignature = signature
                textView.textStorage?.setAttributedString(attributedText())
            }

            let width = viewportSize.width
            let height = viewportSize.height
            guard width > 0, height > 0 else { return }

            let horizontal = width * marginFraction
            if abs(textView.textContainerInset.width - horizontal) > 0.5 {
                textView.textContainerInset = NSSize(width: horizontal, height: 0)
                textView.frame.size.width = width
            }
            coordinator.viewportHeight = height
            if abs(coordinator.readLine - readLine) > 0.0001 {
                coordinator.readLine = readLine
                // La línea ha cambiado de sitio: hay que repintar aunque la
                // posición del guion sea la misma de antes.
                coordinator.lastPaintedOffset = nil
            }

            let travel = Self.fullHeight(of: textView.textLayoutManager) ?? textView.frame.height
            coordinator.engine.measured(travel: travel)

            coordinator.lastPaintedOffset = nil
            coordinator.engine.onPaint?(coordinator.engine.position)
        }

        static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
            coordinator.stop()
        }
    }
#endif
