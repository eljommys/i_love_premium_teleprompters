// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TeleprompterKit",
    // iOS 17 y macOS 14 son el suelo de `@Observable`. En el Mac además hacen
    // falta para `NSView.displayLink(target:selector:)`, el reloj de fotogramas
    // del visor: por debajo solo queda el CVDisplayLink obsoleto.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PrompterCore", targets: ["PrompterCore"]),
        .library(name: "PrompterClient", targets: ["PrompterClient"]),
        .library(name: "PrompterServer", targets: ["PrompterServer"]),
    ],
    targets: [
        // Sin UI y sin red: todo lo que decide qué significa un mensaje vive
        // aquí, y por eso se puede probar sin simulador.
        .target(name: "PrompterCore"),
        .target(name: "PrompterClient", dependencies: ["PrompterCore"]),
        .target(
            name: "PrompterServer",
            dependencies: ["PrompterCore"],
            // La página del modo navegador viaja dentro de la app: sin build de
            // node, sin descargas y sin nada que servir desde fuera.
            resources: [.copy("Resources/web-client.html")]
        ),
        // Anfitrión sin interfaz, solo para las pruebas de interoperabilidad.
        .executableTarget(
            name: "prompter-host", dependencies: ["PrompterServer", "PrompterCore"]),
        .testTarget(name: "PrompterClientTests", dependencies: ["PrompterClient"]),
        .testTarget(
            name: "PrompterServerTests", dependencies: ["PrompterServer", "PrompterClient"]),
        .testTarget(
            name: "PrompterCoreTests",
            dependencies: ["PrompterCore"],
            // Los fixtures los genera `Tools/interop/gen-fixtures.mjs` con la
            // lógica real del servidor web: son el contrato, no un invento.
            resources: [.copy("Fixtures")]
        ),
    ]
)
