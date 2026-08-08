#!/usr/bin/env node

import { createHash } from "node:crypto";
import { promises as fs } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const repoRoot = fileURLToPath(new URL("..", import.meta.url));
const sourceDirectory = "vendor/gfn-web/js";
const outputDirectory = "vendor/gfn-web/source-readable";
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
const outputMappings = new Map([
  ["main.a1f33bd9bb331099.js", "apps/gfn-mall/main.js"],
  ["vendor.5586c78cc423066e.js", "apps/gfn-mall/vendor.js"],
  ["runtime.332dd8696d307479.js", "apps/gfn-mall/bootstrap/runtime.js"],
  ["polyfills.0119af3bec0a10f7.js", "apps/gfn-mall/bootstrap/polyfills.js"],
  ["common.1bb8089756535934.js", "apps/gfn-mall/chunks/common.chunk-076.js"],
  [
    "65.3aba320076f7b6f2.js",
    "apps/gfn-mall/chunks/comlink-worker.chunk-065.js",
  ],
  ["77.1882f9ae7a439de5.js", "apps/gfn-mall/chunks/gfn-mall.chunk-077.js"],
  [
    "599.bfb696c039ce2bd0.js",
    "apps/gfn-mall/chunks/material-text-field.chunk-599.js",
  ],
  [
    "614.7d43af85e6d3b338.js",
    "apps/gfn-mall/chunks/feature-bundle.chunk-614.js",
  ],
  ["626.e518a0378790b839.js", "apps/gfn-mall/chunks/gfn-mall.chunk-626.js"],
  [
    "862.843ae6cca914daac.js",
    "apps/gfn-mall/chunks/settings-keyboard-network.chunk-862.js",
  ],
  [
    "marquee-image-metadata.afc4560e5ac0f3fe.js",
    "apps/gfn-mall/chunks/marquee-image-metadata.chunk-889.js",
  ],
  ["starfleet.js", "apps/account-wrapper/starfleet.js"],
  [
    "7807159bd5184c51e698bfd830efe696723d7e3e.js",
    "apps/account-wrapper/starfleet.js",
  ],
  [
    "v1.9.8-88.219261712f36846bea08.js",
    "apps/account-wrapper/chunks/auth-session.chunk-088.js",
  ],
  [
    "115852c98427b32a883a9ad3d0475ed645cb09e3.js",
    "apps/account-wrapper/chunks/auth-session.chunk-088.js",
  ],
  [
    "v1.9.8-184.d11ee1a6e4ee9c5012ca.js",
    "apps/account-wrapper/chunks/account-wrapper.chunk-184.js",
  ],
  [
    "368d57496a44157ba5c15b9f40deaa49ba7dbdbf.js",
    "apps/account-wrapper/chunks/account-wrapper.chunk-184.js",
  ],
  [
    "v1.9.8-264.e33d70c95b6feba10b05.js",
    "apps/account-wrapper/chunks/account-wrapper.chunk-264.js",
  ],
  [
    "c7c78801f5eca6f8c7128d0a16e4970054f4392f.js",
    "apps/account-wrapper/chunks/account-wrapper.chunk-264.js",
  ],
  [
    "v1.9.8-341.d9c11be1d146e5cf6e53.js",
    "apps/account-wrapper/chunks/account-wrapper.chunk-341.js",
  ],
  [
    "bbeb3c2be788641fc794ffb569d2a86b11a222f0.js",
    "apps/account-wrapper/chunks/account-wrapper.chunk-341.js",
  ],
  [
    "v1.9.8-605.a9d8ca6d408412df3c59.js",
    "apps/account-wrapper/chunks/starfleet-export.chunk-605.js",
  ],
  [
    "6152b8bf95f4c10be8a99cd1d7ac041b1c1f2fd0.js",
    "apps/account-wrapper/chunks/starfleet-export.chunk-605.js",
  ],
  [
    "v1.9.8-669.c07e06084588b09f8f9b.js",
    "apps/account-wrapper/chunks/http-client.chunk-669.js",
  ],
  [
    "0eb058783c6ef832bc958988f5e54017dc43e0f1.js",
    "apps/account-wrapper/chunks/http-client.chunk-669.js",
  ],
  ["44.9119bbd71d18e19fa3db.js", "apps/gfn-home/oauth-redirect.chunk-044.js"],
  ["bundle-search-prod-pub-v3.1.js", "libs/nvidia-search/librarian-search.js"],
  [
    "0359d145d6679053101824ec3f9fe17b78ff26cb.js",
    "libs/nvidia-search/librarian-search.js",
  ],
  ["hints.js", "hints/hints.js"],
  [
    "raw__play__geforcenow__com_____mall__handle-gdn-util.js",
    "raw/play-geforcenow/mall/handle-gdn-util.js",
  ],
  [
    "raw__www__nvidia__com_____assets__starfleet-auth__starfleet.js",
    "raw/www-nvidia/assets/starfleet-auth/starfleet.js",
  ],
]);

const prettier = await loadPrettier();
const prettierVersion = await readPrettierVersion();
const sourceRoot = path.join(repoRoot, sourceDirectory);
const outputRoot = path.join(repoRoot, outputDirectory);
const entries = await fs.readdir(sourceRoot, { withFileTypes: true });
const sourceFiles = entries
  .filter((entry) => entry.isFile() && entry.name.endsWith(".js"))
  .map((entry) => entry.name)
  .sort((left, right) => left.localeCompare(right));

if (sourceFiles.length === 0) {
  throw new Error(`No JavaScript files found in ${sourceDirectory}.`);
}

const sourceRecords = await Promise.all(sourceFiles.map(readSourceRecord));
const recordGroups = groupSourceRecords(sourceRecords);

await fs.rm(outputRoot, { recursive: true, force: true });
await fs.mkdir(outputRoot, { recursive: true });

const manifestFiles = [];

for (const records of recordGroups) {
  const primaryRecord = primarySourceRecord(records);
  const outputRelativePath = outputPathForRecords(records);
  const outputPath = path.join(outputRoot, outputRelativePath);
  const formatted = await formatStable(
    primaryRecord.source,
    javascriptPrettierOptions,
  );
  const outputBuffer = Buffer.from(formatted, "utf8");

  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  await fs.writeFile(outputPath, outputBuffer);

  manifestFiles.push({
    output: path.posix.join(outputDirectory, outputRelativePath),
    canonicalSource: primaryRecord.sourceRelativePath,
    sourceSha256: primaryRecord.sourceSha256,
    sourceBytes: primaryRecord.sourceBytes,
    outputBytes: outputBuffer.byteLength,
    outputSha256: sha256(outputBuffer),
    aliases: records.map(sourceAlias),
    webpack: webpackMetadata(primaryRecord.source),
  });
}

const manifest = {
  sourceDirectory,
  outputDirectory,
  sourceFileCount: sourceRecords.length,
  outputFileCount: manifestFiles.length,
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
  `Generated ${manifestFiles.length} readable vendor source files from ${sourceRecords.length} inputs in ${outputDirectory}.`,
);

async function readSourceRecord(file) {
  const sourcePath = path.join(sourceRoot, file);
  const sourceBuffer = await fs.readFile(sourcePath);
  const source = sourceBuffer.toString("utf8");

  return {
    file,
    source,
    sourceBytes: sourceBuffer.byteLength,
    sourceSha256: sha256(sourceBuffer),
    sourceRelativePath: path.posix.join(sourceDirectory, file),
    sourceMappingURLs: sourceMappingURLs(source),
  };
}

function groupSourceRecords(records) {
  const groups = new Map();

  for (const record of records) {
    const group = groups.get(record.sourceSha256) ?? [];
    group.push(record);
    groups.set(record.sourceSha256, group);
  }

  return [...groups.values()]
    .map((records) => records.toSorted(compareSourceRecords))
    .sort((left, right) =>
      outputPathForRecords(left).localeCompare(outputPathForRecords(right)),
    );
}

function outputPathForRecords(records) {
  const outputPaths = [
    ...new Set(
      records.map((record) => outputMappings.get(record.file)).filter(Boolean),
    ),
  ];

  if (outputPaths.length > 1) {
    throw new Error(
      `Duplicate source content maps to multiple outputs: ${records.map((record) => record.file).join(", ")}`,
    );
  }

  return (
    outputPaths[0] ??
    path.posix.join("unclassified", readableFileName(records[0].file))
  );
}

function primarySourceRecord(records) {
  return records.toSorted(compareSourceRecords)[0];
}

function compareSourceRecords(left, right) {
  return (
    sourceNameWeight(left.file) - sourceNameWeight(right.file) ||
    left.file.localeCompare(right.file)
  );
}

function sourceNameWeight(file) {
  if (/^[0-9a-f]{40}\.js$/i.test(file) || /^\d+\.[0-9a-f]+\.js$/i.test(file)) {
    return 1;
  }

  return 0;
}

function readableFileName(file) {
  return file.replace(/[^a-z0-9_.-]+/gi, "-");
}

function sourceAlias(record) {
  return {
    source: record.sourceRelativePath,
    sourceBytes: record.sourceBytes,
    sourceSha256: record.sourceSha256,
    sourceMappingURLs: record.sourceMappingURLs,
  };
}

function webpackMetadata(source) {
  const namespaces = sortedMatches(source, /webpackChunk[$\w]+/g);
  const chunkIds = sortedMatches(
    source,
    /\.push\(\s*\[\s*\[([^\]]*)\]/g,
    1,
  ).flatMap(chunkIdList);
  const moduleIds = sortedMatches(
    source,
    /(?:^|[,{])\s*(\d+)\s*:\s*(?:\(|function)/g,
    1,
  );

  return {
    namespaces,
    chunkIds: [...new Set(chunkIds)],
    moduleCount: moduleIds.length,
  };
}

function sortedMatches(source, pattern, group = 0) {
  return [
    ...new Set([...source.matchAll(pattern)].map((match) => match[group])),
  ].sort((left, right) =>
    left.localeCompare(right, undefined, { numeric: true }),
  );
}

function chunkIdList(chunkIds) {
  return chunkIds
    .split(",")
    .map((chunkId) => chunkId.trim())
    .filter(Boolean)
    .sort((left, right) =>
      left.localeCompare(right, undefined, { numeric: true }),
    );
}

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
  return source
    .split(/\r?\n/)
    .map((line) =>
      line.match(
        /^\s*(?:(?:\/\/[#@]\s*sourceMappingURL=([^\s]+))|(?:\/\*[#@]\s*sourceMappingURL=([^\s*]+)\s*\*\/))\s*$/,
      ),
    )
    .filter(Boolean)
    .map((match) => match[1] ?? match[2]);
}
