import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cp, mkdtemp, readFile, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

// Exercise the real gate in isolated copies, not a second implementation of it.
const root = fileURLToPath(new URL("..", import.meta.url));
const scratch = await mkdtemp(join(tmpdir(), "innoflow-packed-negative-"));
console.log(`Packed-consumer negative-control artifacts: ${scratch}`);
for (const directory of ["packages", "scripts", "consumer-fixture"]) {
  await cp(join(root, directory), join(scratch, directory), { recursive: true });
}
await symlink(join(root, "node_modules"), join(scratch, "node_modules"), "dir");
const featurePath = join(scratch, "consumer-fixture/feature.mjs");
const feature = await readFile(featurePath, "utf8");
const originalDisplay = "`Count: ${count}`";
assert.equal(feature.split(originalDisplay).length, 2, "The mutation must change exactly one display expression");

async function runCase(name, source) {
  await writeFile(featurePath, source);
  const result = spawnSync(process.execPath, [join(scratch, "scripts/test-packed-consumer.mjs")], {
    cwd: scratch, encoding: "utf8", timeout: 300_000,
    env: { ...process.env, INNOFLOW_FROM_REGISTRY: "0" },
  });
  const output = `${result.stdout ?? ""}\n${result.stderr ?? ""}`;
  await writeFile(join(scratch, `${name}.log`), output);
  if (result.error || result.signal) throw new Error(`Control ${name} did not execute normally: ${result.error ?? result.signal}`);
  return { exitCode: result.status, output };
}

const normal = await runCase("normal", feature);
assert.equal(normal.exitCode, 0, `Normal packed consumer failed:\n${normal.output}`);
assert.match(normal.output, /Packed React .*browser interactions and console passed/);
console.log("[packed-selftest] normal control passed");

const failures = [];
for (const [name, display, diagnostic] of [
  ["wrong-ssr", "`Count: ${count * 10}`", "Packed consumer SSR value mismatch"],
  // Keep the server and first hydration snapshot valid (7), then corrupt only
  // live state (80/90). A hydration error cannot accidentally satisfy this test.
  ["wrong-browser", "`Count: ${count === 7 ? count : count * 10}`", "Packed consumer browser value mismatch: expected Count: 8, actual Count: 80"],
]) {
  const result = await runCase(name, feature.replace(originalDisplay, display));
  if (result.exitCode === 0 || !result.output.includes(diagnostic)) {
    failures.push(`${name}: expected rejection by ${diagnostic}, got exit ${result.exitCode}; see ${scratch}/${name}.log`);
  } else {
    console.log(`[packed-selftest] ${name}: rejected by the actual value oracle`);
  }
}
assert.deepEqual(failures, [], "The packed-consumer gate must reject both independent value mutants");
console.log(`[packed-selftest] Node ${process.versions.node}: normal + SSR/browser negative controls passed`);
