#!/usr/bin/env node

import { createHash } from "node:crypto";
import { promises as fs } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";

const repoRoot = fileURLToPath(new URL("..", import.meta.url));
const sourceDirectory = "vendor/gfn-web/js";
const outputDirectory = "vendor/gfn-web/js-readable";
const sharedPrettierOptions = {
  printWidth: 80,
  tabWidth: 2,
  useTabs: false,
  semi: true,
  singleQuote: false,
  trailingComma: "all",
};
const javascriptPrettierOptions = {
  ...sharedPrettierOptions,
  parser: "babel",
};
const jsonPrettierOptions = {
  ...sharedPrettierOptions,
  parser: "json",
};

const prettier = await loadPrettier();
const prettierVersion = await readPrettierVersion();
const sourceRoot = path.join(repoRoot, sourceDirectory);
const outputRoot = path.join(repoRoot, outputDirectory);
const entries = await fs.readdir(sourceRoot, { withFileTypes: true });
const files = entries
  .filter((entry) => entry.isFile() && entry.name.endsWith(".js"))
  .map((entry) => entry.name)
  .sort((left, right) => left.localeCompare(right));

if (files.length === 0) {
  throw new Error(`No JavaScript files found in ${sourceDirectory}.`);
}

await fs.rm(outputRoot, { recursive: true, force: true });
await fs.mkdir(outputRoot, { recursive: true });

const manifestFiles = [];

for (const file of files) {
  const sourcePath = path.join(sourceRoot, file);
  const outputPath = path.join(outputRoot, file);
  const sourceBuffer = await fs.readFile(sourcePath);
  const source = sourceBuffer.toString("utf8");
  const formatted = await formatStable(source, javascriptPrettierOptions);
  const outputBuffer = Buffer.from(formatted, "utf8");

  await fs.writeFile(outputPath, outputBuffer);

  manifestFiles.push({
    source: path.posix.join(sourceDirectory, file),
    output: path.posix.join(outputDirectory, file),
    sourceBytes: sourceBuffer.byteLength,
    sourceSha256: sha256(sourceBuffer),
    outputBytes: outputBuffer.byteLength,
    outputSha256: sha256(outputBuffer),
    sourceMappingURLs: sourceMappingURLs(source),
  });
}

const manifest = {
  sourceDirectory,
  outputDirectory,
  formatter: {
    name: "prettier",
    version: prettierVersion,
    options: {
      javascript: javascriptPrettierOptions,
      json: jsonPrettierOptions,
    },
  },
  files: manifestFiles,
};

const manifestSource = JSON.stringify(manifest);
const formattedManifest = await formatStable(
  manifestSource,
  jsonPrettierOptions,
);

await fs.writeFile(path.join(outputRoot, "manifest.json"), formattedManifest);

console.log(
  `Generated ${manifestFiles.length} readable vendor files in ${outputDirectory}.`,
);

async function loadPrettier() {
  const prettierPath = path.join(
    repoRoot,
    "tools/vendor-js/node_modules/prettier/index.mjs",
  );

  try {
    return await import(pathToFileURL(prettierPath).href);
  } catch (error) {
    if (error?.code === "ERR_MODULE_NOT_FOUND" || error?.code === "ENOENT") {
      throw new Error(
        "Prettier is not installed. Run `npm --prefix tools/vendor-js ci` first.",
      );
    }

    throw error;
  }
}

async function readPrettierVersion() {
  const packagePath = path.join(
    repoRoot,
    "tools/vendor-js/node_modules/prettier/package.json",
  );
  const packageJson = JSON.parse(await fs.readFile(packagePath, "utf8"));

  if (
    typeof packageJson.version !== "string" ||
    packageJson.version.length === 0
  ) {
    throw new Error("Unable to determine installed Prettier version.");
  }

  return packageJson.version;
}

function sha256(buffer) {
  return createHash("sha256").update(buffer).digest("hex");
}

async function formatStable(source, options) {
  let formatted = source;

  for (let pass = 0; pass < 4; pass += 1) {
    const next = await prettier.format(formatted, options);

    if (next === formatted) {
      return next;
    }

    formatted = next;
  }

  return formatted;
}

function sourceMappingURLs(source) {
  return [
    ...source.matchAll(
      /(?:\/\/[#@]\s*sourceMappingURL=|\/\*[#@]\s*sourceMappingURL=)([^\s*]+)/g,
    ),
  ].map((match) => match[1]);
}
