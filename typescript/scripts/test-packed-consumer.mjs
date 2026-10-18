import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cp, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { chromium } from "playwright";

const root = fileURLToPath(new URL("..", import.meta.url));
const scratch = await mkdtemp(join(tmpdir(), "innoflow-packed-consumer-"));
console.log(`Consumer artifacts: ${scratch}`);
function run(args, cwd = scratch) {
  const result = spawnSync(args[0], args.slice(1), { cwd, encoding: "utf8", timeout: 180_000 });
  if (result.error || result.status !== 0) throw new Error(`${args[0]} failed:\n${result.stdout}\n${result.stderr}\n${result.error ?? ""}`);
  return result.stdout;
}
const react = process.env.INNOFLOW_REACT_VERSION ?? "19.2.8";
assert.match(react, /^(18|19)\.\d+\.\d+$/);
const dependencies = { react, "react-dom": react };
for (const directory of ["core", "react", "testing"]) {
  const manifest = JSON.parse(await readFile(join(root, "packages", directory, "package.json"), "utf8"));
  if (process.env.INNOFLOW_FROM_REGISTRY === "1") {
    dependencies[manifest.name] = manifest.version;
  } else {
    const [packed] = JSON.parse(run(["npm", "pack", `./packages/${directory}`, "--ignore-scripts", "--json", "--pack-destination", scratch], root));
    assert.ok(!packed.files.some(file => file.path.includes(".test.") || file.path.endsWith("tsbuildinfo")), "tests and build state must not ship");
    dependencies[manifest.name] = `file:${join(scratch, packed.filename)}`;
  }
}
const vite = JSON.parse(await readFile(join(root, "node_modules/vite/package.json"), "utf8")).version;
await cp(join(root, "consumer-fixture"), scratch, { recursive: true });
await writeFile(join(scratch, "package.json"), JSON.stringify({ private: true, type: "module", dependencies,
  devDependencies: { vite, typescript: "5.9.3", "@types/react": react.startsWith("18.") ? "18.2.79" : "19.2.14" } }));
await writeFile(join(scratch, "tsconfig.json"), JSON.stringify({ compilerOptions: {
  strict: true, noEmit: true, target: "ES2022", module: "NodeNext", moduleResolution: "NodeNext",
}, include: ["consumer.ts"] }));
run(["npm", "install", "--ignore-scripts", "--no-audit", "--no-fund"]);
run([process.execPath, join(scratch, "node_modules/typescript/bin/tsc"), "-p", "tsconfig.json"]);
console.log(run([process.execPath, "smoke.mjs"]).trim());
run([process.execPath, join(scratch, "node_modules/vite/bin/vite.js"), "build"]);
const { preview } = await import(pathToFileURL(join(scratch, "node_modules/vite/dist/node/index.js")));
const server = await preview({ root: scratch, preview: { host: "127.0.0.1", port: 0 } });
let browser;
let page;
try {
  browser = await chromium.launch({ headless: true });
  const errors = [];
  page = await browser.newPage();
  page.on("pageerror", error => errors.push(String(error)));
  page.on("console", message => { if (message.type() === "error") errors.push(message.text()); });
  const address = server.httpServer.address();
  assert.ok(address && typeof address === "object");
  await page.goto(`http://127.0.0.1:${address.port}`);
  const counter = page.getByRole("status");
  async function requireCount(value) {
    const expected = `Count: ${value}`;
    try {
      await counter.filter({ hasText: new RegExp(`^Count: ${value}$`) }).waitFor({ timeout: 10_000 });
      assert.equal(await counter.textContent(), expected);
    } catch (cause) {
      const actual = await counter.textContent({ timeout: 1_000 }).catch(() => "<missing>");
      throw new Error(`Packed consumer browser value mismatch: expected ${expected}, actual ${actual}`, { cause });
    }
  }
  await requireCount(8);
  await page.getByRole("button", { name: "Increase", exact: true }).click();
  await requireCount(9);
  await page.getByRole("button", { name: "Decrease", exact: true }).click();
  await requireCount(8);
  assert.deepEqual(await page.evaluate(() => window.hydrationErrors), []);
  assert.deepEqual(errors, []);
  await page.screenshot({ path: join(scratch, "consumer.png"), fullPage: true });
  console.log(`Packed React ${react}, Node ${process.versions.node}: typecheck, SSR, hydration, browser interactions and console passed`);
} catch (error) {
  if (page !== undefined) {
    await page.screenshot({ path: join(scratch, "consumer-failed.png"), fullPage: true }).catch(() => {});
  }
  throw error;
} finally {
  await browser?.close();
  await new Promise(resolve => server.httpServer.close(resolve));
}
