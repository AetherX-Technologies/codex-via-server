import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const schemasRoot = path.join(repositoryRoot, "schemas");
const fixturesRoot = path.join(repositoryRoot, "tests", "fixtures");
const schemaNames = ["enrollment-request", "connection-profile", "compatibility"];
const ajv = new Ajv2020({ allErrors: true, strict: true });
addFormats(ajv);

let checkedFixtures = 0;

for (const schemaName of schemaNames) {
  const schemaPath = path.join(schemasRoot, `${schemaName}.schema.json`);
  const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
  const validate = ajv.compile(schema);

  for (const expectedValidity of ["valid", "invalid"]) {
    const fixtureDirectory = path.join(fixturesRoot, schemaName, expectedValidity);
    const fixtureNames = fs.readdirSync(fixtureDirectory).sort();

    if (fixtureNames.length === 0) {
      throw new Error(`No ${expectedValidity} fixtures found for ${schemaName}`);
    }

    for (const fixtureName of fixtureNames) {
      const fixturePath = path.join(fixtureDirectory, fixtureName);
      const fixture = JSON.parse(fs.readFileSync(fixturePath, "utf8"));
      const isValid = validate(fixture);
      const shouldBeValid = expectedValidity === "valid";

      if (isValid !== shouldBeValid) {
        const details = ajv.errorsText(validate.errors, { separator: "\n" });
        throw new Error(`${schemaName}/${expectedValidity}/${fixtureName}: ${details}`);
      }

      checkedFixtures += 1;
    }
  }
}

process.stdout.write(`PASS: ${schemaNames.length} schemas and ${checkedFixtures} fixtures\n`);
