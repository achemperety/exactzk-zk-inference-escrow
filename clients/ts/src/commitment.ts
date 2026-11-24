/**
 * The input commitment of the pinned circuits, computed on the client: EZKL's "hashed/public" input
 * visibility, a Poseidon hash of the quantised input. Each value is rounded to a fixed-point integer
 * at 2^scale (negative values wrap around the BN254 scalar field), written as 32 little-endian bytes,
 * and hashed with EZKL's own Poseidon through its WebAssembly build (@ezkljs/engine, an optional
 * dependency, needed only for live mode). The result is read back as a big-endian 32-byte value, the
 * form the proof's public input and the payment terms use.
 */
import { createRequire } from "node:module";
import type { Hex } from "viem";

const R = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;

function littleEndian(q: bigint): string {
  let s = "";
  for (let i = 0; i < 32; i++) {
    s += Number(q & 0xffn).toString(16).padStart(2, "0");
    q >>= 8n;
  }
  return s;
}

export async function commitment(values: number[], scale = 13): Promise<Hex> {
  const engine = createRequire(import.meta.url)("@ezkljs/engine") as { poseidonHash(message: Uint8ClampedArray): Uint8ClampedArray };
  const felts = values.map(x => {
    const q = BigInt(Math.round(x * 2 ** scale));
    return littleEndian(q < 0n ? q + R : q);
  });
  const out = engine.poseidonHash(new Uint8ClampedArray(Buffer.from(JSON.stringify(felts), "utf8")));
  const le = (JSON.parse(Buffer.from(out).toString("utf8")) as string[][])[0][0];
  const bytes = le.match(/../g)!.reverse().join("");
  return `0x${bytes}` as Hex;
}
