#!/usr/bin/env node
/**
 * Somete a un anfitrión al guion completo del protocolo y escribe un
 * transcript. Sirve para los dos: el servidor de la versión web y el anfitrión
 * nativo tienen que producir el MISMO transcript.
 *
 *   # el de referencia
 *   cd ../../.. && PORT=3400 npm start
 *   node exercise-host.mjs ws://127.0.0.1:3400/ws > web.txt
 *
 *   # el nativo
 *   cd ../../Packages/TeleprompterKit && swift run prompter-host --port 3500
 *   node exercise-host.mjs ws://127.0.0.1:3500/ > nativo.txt
 *
 *   diff web.txt nativo.txt
 *
 * Con `--code 1234` comprueba además el emparejamiento, que el servidor web no
 * tiene: ahí el transcript sí diverge a propósito.
 */
import { WebSocket } from "ws";

const args = process.argv.slice(2);
const url = args.find((a) => a.startsWith("ws://")) ?? "ws://127.0.0.1:3500/";
const codeIndex = args.indexOf("--code");
const code = codeIndex >= 0 ? args[codeIndex + 1] : undefined;

const log = [];
let failures = 0;

function record(line) {
  log.push(line);
}

function check(label, condition, detail = "") {
  record(`${condition ? "ok  " : "FALLO"} ${label}${detail ? ` — ${detail}` : ""}`);
  if (!condition) failures += 1;
}

/** Un cliente que apunta todo lo que recibe. */
function connect(role) {
  const socket = new WebSocket(url);
  const received = [];
  const ready = new Promise((resolve, reject) => {
    socket.once("open", () => {
      socket.send(JSON.stringify(code ? { type: "hello", role, code } : { type: "hello", role }));
      resolve();
    });
    socket.once("error", reject);
  });
  socket.on("message", (data) => received.push(JSON.parse(data.toString())));
  return {
    socket,
    received,
    ready,
    send: (patch) => socket.send(JSON.stringify({ type: "update", patch })),
    close: () => socket.close(),
    /** Espera a que llegue un mensaje que cumpla la condición. */
    async waitFor(predicate, ms = 3000) {
      const deadline = Date.now() + ms;
      while (Date.now() < deadline) {
        const hit = received.find(predicate);
        if (hit) return hit;
        await new Promise((r) => setTimeout(r, 20));
      }
      return undefined;
    },
  };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const visor = connect("prompter");
  const mando = connect("remote");
  await Promise.all([visor.ready, mando.ready]);
  await sleep(300);

  // 1. Al conectar llega el estado completo.
  const estado = await visor.waitFor((m) => m.type === "state");
  check("al conectar llega el estado completo", !!estado);
  if (estado) {
    const claves = Object.keys(estado.state).sort().join(",");
    check(
      "el estado trae las diez claves",
      claves === "docHeight,fontSize,lineHeight,margin,mirrorH,mirrorV,playing,position,speed,text",
      claves,
    );
    check("y viene con los recuentos", typeof estado.clients?.prompter === "number");
  }

  // 2. Los recuentos reflejan los papeles declarados.
  const recuentos = await mando.waitFor(
    (m) => m.clients?.prompter >= 1 && m.clients?.remote >= 1,
  );
  check("los recuentos ven al visor y al mando", !!recuentos, JSON.stringify(recuentos?.clients));

  // 3. Un cambio llega a los demás, pero no vuelve al emisor.
  mando.received.length = 0;
  visor.received.length = 0;
  mando.send({ speed: 77 });
  const reparto = await visor.waitFor((m) => m.type === "patch" && m.patch.speed === 77);
  check("el cambio del mando llega al visor", !!reparto);
  await sleep(200);
  check(
    "y no le vuelve al emisor",
    !mando.received.some((m) => m.type === "patch" && m.patch.speed === 77),
  );

  // 4. Los valores fuera de rango vuelven acotados.
  visor.received.length = 0;
  mando.send({ fontSize: 9999, lineHeight: -5, margin: 999, position: 3, docHeight: 1e12 });
  const acotado = await visor.waitFor((m) => m.type === "patch" && m.patch.fontSize !== undefined);
  check("el cuerpo de letra se acota a 160", acotado?.patch.fontSize === 160, `${acotado?.patch.fontSize}`);
  check("el interlineado se acota a 1", acotado?.patch.lineHeight === 1, `${acotado?.patch.lineHeight}`);
  check("el margen se acota a 30", acotado?.patch.margin === 30, `${acotado?.patch.margin}`);
  check("la posición se acota a 1", acotado?.patch.position === 1, `${acotado?.patch.position}`);
  check("el recorrido se acota a 1e7", acotado?.patch.docHeight === 1e7, `${acotado?.patch.docHeight}`);

  // 5. Las claves desconocidas y los tipos equivocados se descartan.
  visor.received.length = 0;
  mando.send({ chorrada: true, speed: "rapido", margin: 11 });
  const filtrado = await visor.waitFor((m) => m.type === "patch");
  check(
    "solo pasa la clave buena",
    filtrado && JSON.stringify(filtrado.patch) === JSON.stringify({ margin: 11 }),
    JSON.stringify(filtrado?.patch),
  );

  // 6. Un patch que se queda en nada no se reparte.
  visor.received.length = 0;
  mando.send({ chorrada: true });
  mando.send({});
  await sleep(300);
  check("un patch vacío no se reparte", visor.received.length === 0);

  // 7. Un mensaje desconocido no tumba la conexión.
  mando.socket.send(JSON.stringify({ type: "vete-a-saber" }));
  mando.socket.send("esto no es JSON");
  await sleep(200);
  check("un mensaje raro no cierra el socket", mando.socket.readyState === WebSocket.OPEN);

  // 8. Repetir el saludo cambia de papel sin reconectar.
  visor.received.length = 0;
  mando.socket.send(JSON.stringify(code ? { type: "hello", role: "editor", code } : { type: "hello", role: "editor" }));
  const cambio = await visor.waitFor((m) => m.type === "clients" && m.clients.editor >= 1);
  check("cambiar de papel actualiza los recuentos", !!cambio, JSON.stringify(cambio?.clients));
  check("y no cierra el socket", mando.socket.readyState === WebSocket.OPEN);

  // 9. Al irse un aparato, los recuentos lo notan.
  visor.received.length = 0;
  mando.close();
  const baja = await visor.waitFor((m) => m.type === "clients" && m.clients.editor === 0);
  check("al desconectarse, los recuentos bajan", !!baja, JSON.stringify(baja?.clients));

  visor.close();
  await sleep(100);
}

try {
  await main();
} catch (error) {
  record(`FALLO excepción — ${error.message}`);
  failures += 1;
}

console.log(log.join("\n"));
console.log(failures === 0 ? "\nTODO CORRECTO" : `\n${failures} COMPROBACIONES FALLIDAS`);
process.exit(failures === 0 ? 0 : 1);
