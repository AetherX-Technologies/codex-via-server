import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const [schemaName, instancePathArgument] = process.argv.slice(2);

if (!schemaName || !instancePathArgument) {
  throw new Error("usage: validate-instance.mjs <schema-name> <instance.json>");
}

const schemaPath = path.join(repositoryRoot, "schemas", `${schemaName}.schema.json`);
const instancePath = path.resolve(instancePathArgument);
const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
const instance = JSON.parse(fs.readFileSync(instancePath, "utf8"));
const ajv = new Ajv2020({ allErrors: true, strict: true });
addFormats(ajv);
const validate = ajv.compile(schema);

if (!validate(instance)) {
  throw new Error(ajv.errorsText(validate.errors, { separator: "\n" }));
}

process.stdout.write(`PASS: ${schemaName} instance ${instancePath}\n`);
