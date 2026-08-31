import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const compatibilityPath = path.join(repositoryRoot, "compatibility.json");
const schemaPath = path.join(repositoryRoot, "schemas", "compatibility.schema.json");
const versionPath = path.join(repositoryRoot, "VERSION");
const packagePath = path.join(repositoryRoot, "package.json");
const compatibility = JSON.parse(fs.readFileSync(compatibilityPath, "utf8"));
const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
const projectVersion = fs.readFileSync(versionPath, "utf8").trim();
const packageVersion = JSON.parse(fs.readFileSync(packagePath, "utf8")).version;
const ajv = new Ajv2020({ allErrors: true, strict: true });
addFormats(ajv);

const validateSchema = ajv.compile(schema);

function compareVersionCore(left, right) {
  const leftCore = left.split("-", 1)[0].split(".").map(Number);
  const rightCore = right.split("-", 1)[0].split(".").map(Number);

  for (let index = 0; index < 3; index += 1) {
    if (leftCore[index] !== rightCore[index]) {
      return leftCore[index] - rightCore[index];
    }
  }

  return 0;
}

function validateInvariants(manifest) {
  const errors = [];

  if (manifest.project_version !== projectVersion) {
    errors.push(`project_version must equal VERSION (${projectVersion})`);
  }

  if (manifest.project_version !== packageVersion) {
    errors.push(`project_version must equal package.json (${packageVersion})`);
  }

  if (!manifest.codex.candidates.includes(manifest.codex.last_tested)) {
    errors.push("codex.last_tested must be one of codex.candidates");
  }

  if (manifest.codex.minimum_supported !== null && !manifest.codex.candidates.includes(manifest.codex.minimum_supported)) {
    errors.push("codex.minimum_supported must be null or one of codex.candidates");
  }

  if (manifest.codex.minimum_supported !== null && compareVersionCore(manifest.codex.minimum_supported, manifest.codex.last_tested) > 0) {
    errors.push("codex.minimum_supported cannot be newer than codex.last_tested");
  }

  if (compareVersionCore(manifest.cliproxyapi.minimum_supported, manifest.cliproxyapi.last_tested) > 0) {
    errors.push("cliproxyapi.minimum_supported cannot be newer than cliproxyapi.last_tested");
  }

  return errors;
}

if (!validateSchema(compatibility)) {
  throw new Error(ajv.errorsText(validateSchema.errors, { separator: "\n" }));
}

const invariantErrors = validateInvariants(compatibility);

if (invariantErrors.length > 0) {
  throw new Error(invariantErrors.join("\n"));
}

const invalidManifests = [
  {
    name: "project version drift",
    value: { ...compatibility, project_version: "9.9.9" }
  },
  {
    name: "untested minimum Codex version",
    value: {
      ...compatibility,
      codex: { ...compatibility.codex, minimum_supported: "0.148.0" }
    }
  },
  {
    name: "untested last Codex version",
    value: {
      ...compatibility,
      codex: { ...compatibility.codex, last_tested: "0.152.0" }
    }
  },
  {
    name: "reversed CLIProxyAPI range",
    value: {
      ...compatibility,
      cliproxyapi: { minimum_supported: "8.0.0", last_tested: "7.2.146" }
    }
  }
];

for (const invalidManifest of invalidManifests) {
  const schemaValid = validateSchema(invalidManifest.value);
  const errors = schemaValid ? validateInvariants(invalidManifest.value) : validateSchema.errors;

  if (schemaValid && errors.length === 0) {
    throw new Error(`Invalid manifest accepted: ${invalidManifest.name}`);
  }
}

process.stdout.write(`PASS: compatibility manifest ${compatibility.project_version}\n`);
