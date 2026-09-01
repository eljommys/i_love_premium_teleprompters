#!/usr/bin/env node
// Punto de entrada de `npx github:eljommys/i_love_premium_teleprompters`.
//
// Arranca el servidor ya compilado que hay en `dist/`. No se ejecuta el
// `server.ts` original a propósito: Node se niega a quitar los tipos de un
// fichero .ts que esté dentro de node_modules, que es exactamente donde acaba
// el paquete cuando se instala.

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join, resolve } from "node:path";

const PACKAGE_DIR = resolve(import.meta.dirname, "..");
const SERVER = join(PACKAGE_DIR, "dist", "server.js");

// Falta lo construido: pasa al clonar el repositorio y lanzarlo a mano. Se
// construye una vez y las siguientes veces arranca directo.
if (!existsSync(SERVER) || !existsSync(join(PACKAGE_DIR, ".next"))) {
  console.log("\n  Primera vez: construyendo la aplicación…\n");
  const build = spawnSync("npm", ["run", "build"], { cwd: PACKAGE_DIR, stdio: "inherit" });
  if (build.status !== 0) process.exit(build.status ?? 1);
}

// El servidor corre desde dist/, así que no puede deducir dónde está la
// aplicación de Next mirándose los pies: se le dice.
process.env.TELEPROMPTER_APP_DIR = PACKAGE_DIR;
process.env.NODE_ENV ??= "production";
await import(SERVER);
