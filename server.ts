import { createServer } from "node:http";
import { createServer as createProbe } from "node:net";
import { readFile, rename, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import next from "next";
import { WebSocketServer, type WebSocket } from "ws";
import {
  DEFAULT_STATE,
  LIVE_KEYS,
  PERSISTED_KEYS,
  sanitizePatch,
  type Role,
  type ServerMessage,
  type TeleprompterState,
} from "./lib/state.ts";
import { localAddresses } from "./lib/network.ts";

/**
 * Puerto por el que se empieza a buscar. Si está ocupado —otra copia del
 * teleprompter, un `next dev` de otro proyecto— se prueba el siguiente. Sin
 * esto, arrancar con el 3000 pillado se saldaba con un EADDRINUSE y nada más.
 */
const FIRST_PORT = Number(process.env.PORT ?? 3000);
const HOST = "0.0.0.0";
const DEV = process.env.NODE_ENV !== "production";
/**
 * La aplicación de Next vive junto al código del servidor, no en el directorio
 * desde el que se lanza: al ejecutarlo con `npx` el paquete está en la caché de
 * npm y el directorio actual es cualquier otro.
 *
 * En desarrollo esto es la raíz del proyecto. Distribuido, el servidor corre
 * compilado desde `dist/`, así que el lanzador le pasa la raíz del paquete.
 */
const APP_DIR = process.env.TELEPROMPTER_APP_DIR ?? import.meta.dirname;
/**
 * El guion, en cambio, sí se guarda donde lo lanzas. Así cada carpeta tiene el
 * suyo y no se pierde al vaciarse la caché de npx.
 */
const STATE_FILE = resolve(process.cwd(), "state.json");
const ROLES: Role[] = ["editor", "prompter", "remote", "home"];

// ---------------------------------------------------------------- estado

let state: TeleprompterState = { ...DEFAULT_STATE };

async function loadState() {
  let raw: string;
  try {
    raw = await readFile(STATE_FILE, "utf8");
  } catch {
    return; // Primer arranque: valen los valores por defecto.
  }
  try {
    state = { ...DEFAULT_STATE, ...sanitizePatch(JSON.parse(raw) as unknown) };
  } catch {
    // Un fichero ilegible se aparta en vez de sobrescribirse a la primera:
    // dentro puede estar el único guion que había.
    console.error(`state.json no se pudo leer; se aparta como ${STATE_FILE}.bak`);
    await rename(STATE_FILE, `${STATE_FILE}.bak`).catch(() => {});
  }
}

let saveTimer: NodeJS.Timeout | undefined;
let saveDueAt = Infinity;

/**
 * Guarda en disco con retardo. Editar el guion o tocar un ajuste se guarda
 * enseguida; la posición, que cambia decenas de veces por segundo mientras se
 * lee o se arrastra, espera mucho más: reescribir el guion entero varias veces
 * por segundo no aportaría nada.
 */
function scheduleSave(delay: number) {
  const dueAt = Date.now() + delay;
  // Un guardado urgente ya pendiente no se retrasa por uno perezoso posterior.
  if (saveTimer && dueAt >= saveDueAt) return;
  clearTimeout(saveTimer);
  saveDueAt = dueAt;
  saveTimer = setTimeout(() => {
    saveTimer = undefined;
    saveDueAt = Infinity;
    void save();
  }, delay);
  saveTimer.unref();
}

/**
 * Escribe a un temporal y renombra. El renombrado es atómico, así que un corte
 * a media escritura deja intacto el guion anterior en vez de un fichero a
 * medias. Las escrituras se encadenan para que dos no se pisen.
 */
let writing: Promise<void> = Promise.resolve();

function save(): Promise<void> {
  const snapshot = Object.fromEntries(PERSISTED_KEYS.map((key) => [key, state[key]]));
  writing = writing.then(async () => {
    const temporary = `${STATE_FILE}.tmp`;
    try {
      await writeFile(temporary, JSON.stringify(snapshot, null, 2));
      await rename(temporary, STATE_FILE);
    } catch (error) {
      console.error("No se pudo guardar state.json:", error);
    }
  });
  return writing;
}

/** Claves cuyo guardado puede esperar, para consultarlas sin pelear con TypeScript. */
const liveKeys: ReadonlySet<string> = new Set(LIVE_KEYS);
const persistedKeys: ReadonlySet<string> = new Set(PERSISTED_KEYS);

// -------------------------------------------------------------- clientes

const roleOf = new Map<WebSocket, Role>();
/** Sockets que han dado señales de vida desde la última ronda de pings. */
const alive = new WeakSet<WebSocket>();

function clientCounts(): Record<Role, number> {
  const counts = Object.fromEntries(ROLES.map((role) => [role, 0])) as Record<Role, number>;
  for (const role of roleOf.values()) counts[role] += 1;
  return counts;
}

const wss = new WebSocketServer({ noServer: true });

function send(socket: WebSocket, message: ServerMessage) {
  if (socket.readyState === socket.OPEN) socket.send(JSON.stringify(message));
}

function broadcast(message: ServerMessage, except?: WebSocket) {
  for (const client of wss.clients) {
    if (client !== except) send(client as WebSocket, message);
  }
}

wss.on("connection", (socket: WebSocket) => {
  roleOf.set(socket, "home");
  alive.add(socket);
  socket.on("pong", () => alive.add(socket));
  send(socket, { type: "state", state, clients: clientCounts() });
  broadcast({ type: "clients", clients: clientCounts() });

  socket.on("message", (data) => {
    let message: unknown;
    try {
      message = JSON.parse(data.toString());
    } catch {
      return;
    }
    if (typeof message !== "object" || message === null) return;
    const { type } = message as { type?: unknown };

    if (type === "hello") {
      const { role } = message as { role?: unknown };
      if (typeof role === "string" && ROLES.includes(role as Role)) {
        roleOf.set(socket, role as Role);
        broadcast({ type: "clients", clients: clientCounts() });
      }
      return;
    }

    if (type === "update") {
      const patch = sanitizePatch((message as { patch?: unknown }).patch);
      if (Object.keys(patch).length === 0) return;
      state = { ...state, ...patch };
      // El emisor ya aplicó el cambio en local: reenviarlo provocaría saltos.
      broadcast({ type: "patch", patch }, socket);

      const keys = Object.keys(patch);
      if (keys.some((key) => persistedKeys.has(key) && !liveKeys.has(key))) scheduleSave(500);
      else if (keys.some((key) => liveKeys.has(key))) scheduleSave(5000);
    }
  });

  socket.on("close", () => {
    roleOf.delete(socket);
    broadcast({ type: "clients", clients: clientCounts() });
  });

  socket.on("error", () => socket.terminate());
});

/**
 * Un cliente que desaparece sin cerrar el socket —el iPad se duerme, el móvil
 * se va de la Wi-Fi, se cierra la tapa del portátil— dejaría su conexión
 * colgada para siempre y el recuento de aparatos mentiría. Se le manda un ping
 * y, si no ha contestado para la ronda siguiente, se le desconecta.
 */
const heartbeat = setInterval(() => {
  for (const client of wss.clients) {
    const socket = client as WebSocket;
    if (!alive.has(socket)) {
      socket.terminate();
      continue;
    }
    alive.delete(socket);
    socket.ping();
  }
}, 30_000);
heartbeat.unref();

// --------------------------------------------------------------- arranque

/** Cuántos puertos se prueban antes de rendirse. */
const PORT_ATTEMPTS = 50;

/**
 * Abre y cierra un servidor de prueba para saber si el puerto está libre. Se
 * comprueba antes de arrancar, y no reintentando sobre el servidor real,
 * porque a Next hay que decirle el puerto al construirla.
 */
function isFree(port: number): Promise<boolean> {
  return new Promise((done) => {
    const probe = createProbe();
    probe.once("error", () => done(false));
    probe.once("listening", () => probe.close(() => done(true)));
    probe.listen(port, HOST);
  });
}

async function findPort(first: number): Promise<number> {
  for (let port = first; port < first + PORT_ATTEMPTS; port += 1) {
    if (await isFree(port)) return port;
  }
  throw new Error(
    `No hay ningún puerto libre entre el ${first} y el ${first + PORT_ATTEMPTS - 1}.`,
  );
}

const PORT = await findPort(FIRST_PORT);
// La portada genera los QR con la IP local y el puerto; como este ya no es
// siempre el pedido, se le deja escrito el que ha salido.
process.env.PORT = String(PORT);

const app = next({ dev: DEV, dir: APP_DIR, hostname: HOST, port: PORT });

await loadState();
await app.prepare();

// Ambos handlers solo existen una vez que Next está preparado.
const handle = app.getRequestHandler();
const upgradeHandler = app.getUpgradeHandler();

const server = createServer((req, res) => {
  handle(req, res);
});

server.on("upgrade", (req, socket, head) => {
  const pathname = new URL(req.url ?? "/", "http://localhost").pathname;
  if (pathname === "/ws") {
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit("connection", ws, req));
    return;
  }
  // Cualquier otro upgrade (HMR de Next en desarrollo) lo gestiona Next.
  upgradeHandler(req, socket, head);
});

// Al cerrar el servidor puede haber un guardado esperando su turno (la posición
// espera 5 s). Se vuelca antes de salir para no perder por dónde ibas.
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.once(signal, async () => {
    clearTimeout(saveTimer);
    await save();
    process.exit(0);
  });
}

server.listen(PORT, HOST, () => {
  const hosts = ["localhost", ...localAddresses()];
  console.log(`\n  fuck_premium_teleprompters ${DEV ? "(desarrollo)" : "(producción)"}\n`);
  if (PORT !== FIRST_PORT) console.log(`  (el puerto ${FIRST_PORT} estaba ocupado)\n`);
  for (const host of hosts) {
    console.log(`  http://${host}:${PORT}`);
  }
  console.log("\n  Editor (Mac)     /editor");
  console.log("  Visor (iPad)     /prompter");
  console.log("  Mando (móvil)    /remote\n");
});
