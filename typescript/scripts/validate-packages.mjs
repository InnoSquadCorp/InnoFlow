import { spawnSync } from "node:child_process";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { posix } from "node:path";
import { fileURLToPath } from "node:url";

const packageDirectories = [
  "packages/core",
  "packages/react",
  "packages/testing",
];
const canonicalLicense = await readFile(new URL("../../LICENSE", import.meta.url), "utf8");

function run(command, args, quiet = false) {
  const result = spawnSync(command, args, {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
    stdio: "pipe",
  });
  if (result.status !== 0) {
    process.stderr.write(result.stdout);
    process.stderr.write(result.stderr);
    process.exit(result.status ?? 1);
  }
  if (!quiet) process.stdout.write(result.stdout);
  return result.stdout;
}

for (const directory of packageDirectories) {
  process.stdout.write(`\nValidating ${directory}\n`);
  assert.equal(await readFile(new URL(`../${directory}/LICENSE`, import.meta.url), "utf8"),
    canonicalLicense, `${directory}: LICENSE must match the repository's canonical license`);
  run(process.execPath, [fileURLToPath(new URL("../node_modules/.bin/publint", import.meta.url)), directory, "--strict"]);
  run(process.execPath, [
    fileURLToPath(new URL("../node_modules/.bin/attw", import.meta.url)),
    `./${directory}`,
    "--pack",
    "--profile",
    "esm-only",
    "--no-color",
  ]);
  const [packed] = JSON.parse(run("npm", ["pack", `./${directory}`, "--dry-run", "--json"], true));
  const shipped = new Set(packed.files.map(file => file.path));
  assert.ok(shipped.has("LICENSE") && shipped.has("README.md"));
  assert.ok(![...shipped].some(file => file.includes(".test.") || file.endsWith("tsbuildinfo")));
  for (const file of shipped) {
    if (!file.endsWith(".map")) continue;
    const map = JSON.parse(await readFile(new URL(`../${directory}/${file}`, import.meta.url), "utf8"));
    for (const [index, source] of map.sources.entries()) {
      const target = posix.normalize(posix.join(posix.dirname(file), source));
      assert.ok(shipped.has(target), `${file} references absent source ${target}`);
      if (file.endsWith(".js.map")) {
        assert.equal(map.sourcesContent[index], await readFile(new URL(`../${directory}/${target}`, import.meta.url), "utf8"));
      }
    }
  }
  console.log(`${directory}: ${packed.entryCount} files, ${packed.unpackedSize} bytes; source maps and package contents verified`);
}
