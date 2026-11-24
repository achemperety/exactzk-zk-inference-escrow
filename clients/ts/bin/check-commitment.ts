/**
 * Checks the client's input commitment (src/commitment.ts, live mode) against the published proof:
 * the commitment of the published solo input, 784 features and 5 nonce values, computed here with
 * EZKL's Poseidon, must equal the input commitment the stored proof carries. Nothing is proved.
 *
 *   npm run check-commitment [-- <input.json>]
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { commitment } from "../src/commitment.js";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");
const file = process.argv[2] ?? join(ROOT, "circuits", "spike-mlp", "run_t3_k5_nonces", "input.json");
const values: number[] = JSON.parse(readFileSync(file, "utf8")).input_data[0];
const published = JSON.parse(readFileSync(join(ROOT, "clients", "ts", "published", "solo-proof.json"), "utf8")).inputCommitment;
const computed = await commitment(values);
console.log(`values:     ${values.length} (784 features, 5 nonces)`);
console.log(`computed:   ${computed}`);
console.log(`published:  ${published}`);
console.log(computed.toLowerCase() === published.toLowerCase() ? "MATCH" : "DIFFER");
process.exit(computed.toLowerCase() === published.toLowerCase() ? 0 : 1);
