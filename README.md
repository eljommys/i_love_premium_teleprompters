# i_love_premium_teleprompters

Teleprompter en red local. El Mac hace de servidor, el iPad muestra el guion en
espejo y el móvil lo controla en tiempo real.

Sin cuota, sin cuenta, sin marca de agua y sin nube: el guion no sale de tu Wi-Fi.

## Arrancar

Sin instalar nada:

```bash
npx fck-premium-teleprompters
```

O instalado como comando, para tenerlo siempre a mano:

```bash
npm install -g fck-premium-teleprompters
fck-premium-teleprompters
```

Sí, falta una letra. El registro de npm tiene un filtro de palabrotas y devuelve
*«That word is not allowed»* al publicar, así que ahí el paquete va censurado.
En todo lo demás el nombre se queda como estaba.

Necesita **Node 20.19 o superior**. El paquete viene ya construido, así que
arranca en unos segundos.

Al arrancar imprime las direcciones de la red local. Abre la de `localhost` en el
Mac: la página de inicio trae los códigos QR del visor y del mando para abrirlos
en el iPad y el móvil sin teclear nada.

El guion se guarda en un `state.json` **en la carpeta desde la que lanzas el
comando**, así que cada proyecto puede tener el suyo.

El puerto se busca solo: empieza por el 3000 y, si está ocupado, prueba el
siguiente hasta dar con uno libre —así puedes tener dos tomas abiertas a la vez—.
Para empezar a buscar por otro, `PORT=4000 npx fck-premium-teleprompters`.

### Desde el código

```bash
git clone https://github.com/eljommys/i_love_premium_teleprompters.git
cd i_love_premium_teleprompters
npm install
npm start
```

Para desarrollar, `npm run dev` (recarga en caliente, algo más lento).

## Las tres vistas

| Ruta        | Dispositivo | Qué hace                                                           |
| ----------- | ----------- | ------------------------------------------------------------------ |
| `/editor`   | Mac         | Pegar el guion y ajustar velocidad, cuerpo de letra y espejo.       |
| `/prompter` | iPad        | Guion a pantalla completa, espejo y barra de progreso a la derecha. |
| `/remote`   | Móvil       | El guion en vivo: tocarlo reproduce o pausa, arrastrarlo lo mueve.  |

Todos los dispositivos comparten un mismo estado por WebSocket: lo que se cambia
en uno aparece al instante en los demás.

En el mando ves el mismo guion que el iPad, sincronizado, con su línea de lectura
al 40 % de la pantalla. Un toque en cualquier parte del texto reproduce o pausa.
Arrastrarlo verticalmente lo desplaza uno a uno con el dedo, y agarrarlo detiene
la marcha, como sujetar el papel con la mano. Abajo, ⚙ abre los ajustes:
velocidad, cuerpo de letra del visor y del propio móvil, interlineado, márgenes,
espejos y volver al inicio.

## Detalles de montaje

- **Espejo H** para el cristal del teleprompter (invierte izquierda-derecha).
  Añade **Espejo V** si el iPad va boca abajo bajo el cristal.
- El visor mantiene la pantalla del iPad encendida mientras esté abierto
  (Wake Lock). En iPadOS conviene abrirlo desde Safari y dejarlo en primer plano.
- El guion y los ajustes se guardan en `state.json`, así que sobreviven a un
  reinicio del servidor. Ese fichero no se versiona.

## Cómo está montado

- `server.ts` — servidor único: sirve Next.js y atiende los WebSockets en `/ws`.
  Guarda el estado escribiendo a un temporal y renombrando, así que un corte no
  deja el guion a medias. Los ajustes se guardan a los 0,5 s y la posición a los
  5 s, y lo pendiente se vuelca al cerrar.
- `lib/state.ts` — forma del estado compartido, límites de cada ajuste y saneado
  de los mensajes que llegan de los clientes.
- `lib/useTeleprompter.ts` — hook de cliente: conexión, reconexión automática y
  aplicación de cambios.
- `lib/useScriptScroll.ts` — la mecánica de desplazamiento que comparten el visor
  y el mando: mide el recorrido, anima fuera de React y pinta con `transform`.

Cada pantalla anima el desplazamiento por su cuenta y trata lo que llega por la
red como una posición a la que **acercarse**, no a la que saltar. Por eso el
arrastre desde el móvil se ve continuo en el iPad aunque las posiciones lleguen a
golpes de 33 ms. Mientras se reproduce, esa posición objetivo avanza al mismo
ritmo que la lectura; si no, el desfase se estancaría y el visor se quedaría
congelado a mitad de toma.
