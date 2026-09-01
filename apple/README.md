# Universal Teleprompter — apps nativas

Una sola aplicación para Mac, iPad y iPhone. Los tres modos —**Editor**,
**Visor** y **Mando**— están en las tres máquinas, y cualquiera de ellas puede
alojar la sesión o unirse a la de otra.

Convive con la versión web de la raíz del repositorio: hablan **el mismo
protocolo**, así que un aparato nativo puede unirse a una sesión servida por
`npm start` y viceversa.

## Abrir el proyecto

El `.xcodeproj` se genera; la fuente de verdad es `project.yml`.

```bash
brew install xcodegen   # una sola vez
cd apple && xcodegen generate && open Teleprompter.xcodeproj
```

## Qué hay aquí

```
apple/
├── project.yml                  la definición del proyecto
├── Teleprompter/                la interfaz (SwiftUI)
│   ├── AppModel.swift           qué modo, y de quién es la sesión
│   ├── Views/                   Editor, Visor, Mando, panel de sesión
│   ├── Prompter/                el motor de scroll y el dibujado del guion
│   └── Resources/               catálogos de cadenas (es + en) y assets
├── Packages/TeleprompterKit/    la lógica, sin interfaz y con pruebas
│   ├── PrompterCore             estado, protocolo, saneado, seguimiento
│   ├── PrompterClient           unirse a otra sesión (NWConnection, Bonjour)
│   └── PrompterServer           alojar la sesión (NWListener, persistencia)
└── Tools/interop/               pruebas contra la implementación original
```

## Pruebas

La lógica se prueba sin simulador:

```bash
cd apple/Packages/TeleprompterKit && swift test
```

Las pruebas del protocolo comparan contra **fixtures generados ejecutando el
servidor web** (`lib/state.ts`), así que comprobar Swift es comprobarlo contra
la implementación original y no contra lo que creíamos recordar de ella.

### Interoperabilidad con la versión web

El servidor de la raíz hace de anfitrión de referencia:

```bash
npm start                                    # en la raíz del repositorio
cd apple/Packages/TeleprompterKit
TELEPROMPTER_INTEROP=127.0.0.1:3000 swift test --filter Interop
```

Y al revés, un cliente de Node somete al anfitrión nativo al mismo guion de
comprobaciones. Los dos transcripts tienen que salir iguales:

```bash
cd apple/Packages/TeleprompterKit && swift run prompter-host --port 3500
node apple/Tools/interop/exercise-host.mjs ws://127.0.0.1:3500/
```

## Antes de subir a la App Store

- El identificador `com.rackslabs.teleprompter` **no se puede cambiar** después
  de la primera subida. El nombre visible sí.
- El nombre del paquete npm no puede aparecer en ningún sitio visible.
- La aplicación tiene que seguir siendo utilizable entera **en un solo aparato y
  con el permiso de red local denegado**: es como la va a probar quien la revise.
