// storage.rules must deny every read and every write, to every caller.
// Same argument as the Firestore suite: nothing but the Admin SDK, which
// bypasses rules, is meant to reach the bucket.

import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import {
  assertFails,
  type RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  deleteObject,
  getBytes,
  getMetadata,
  listAll,
  ref,
  uploadBytes,
} from "firebase/storage";
import {
  CALLERS,
  OTHER_UID,
  UID,
  everyAllowIsDenied,
  makeTestEnv,
  rulesSource,
} from "./helpers";

let env: RulesTestEnvironment;

const BYTES = new Uint8Array([1, 2, 3]);

/** [label, object path, its prefix] */
const OBJECTS = [
  ["the caller's own object", `users/${UID}/avatar.png`, `users/${UID}`],
  ["another user's object", `users/${OTHER_UID}/avatar.png`, `users/${OTHER_UID}`],
  ["reference data", "refdata/cycle-phases.json", "refdata"],
  ["an arbitrary path", "anything/at-all.txt", "anything"],
  ["a deeply nested arbitrary path", "a/b/c/d.bin", "a/b/c"],
] as const;

beforeAll(async () => {
  env = await makeTestEnv();
  await env.clearStorage();

  // Seed real objects with rules off, so the read tests prove existing objects
  // are unreachable rather than merely absent.
  await env.withSecurityRulesDisabled(async (ctx) => {
    const storage = ctx.storage();
    for (const [, path] of OBJECTS) {
      await uploadBytes(ref(storage, path), BYTES);
    }
  });
});

afterAll(async () => {
  await env?.cleanup();
});

describe("storage.rules denies", () => {
  for (const [callerLabel, makeCaller] of CALLERS) {
    describe(callerLabel, () => {
      for (const [objectLabel, path, prefix] of OBJECTS) {
        describe(objectLabel, () => {
          const storage = () => makeCaller(env).storage();

          test("download", async () => {
            await assertFails(getBytes(ref(storage(), path)));
          });

          test("read metadata", async () => {
            await assertFails(getMetadata(ref(storage(), path)));
          });

          test("list", async () => {
            await assertFails(listAll(ref(storage(), prefix)));
          });

          test("upload a new object", async () => {
            await assertFails(uploadBytes(ref(storage(), `${path}.new`), BYTES));
          });

          test("overwrite", async () => {
            await assertFails(uploadBytes(ref(storage(), path), BYTES));
          });

          test("delete", async () => {
            await assertFails(deleteObject(ref(storage(), path)));
          });
        });
      }
    });
  }
});

test("storage.rules has no rule allowing anything", () => {
  expect(everyAllowIsDenied(rulesSource("storage.rules"))).toEqual([]);
});
