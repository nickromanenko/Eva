// firestore.rules must deny every read and every write, to every caller.
//
// The case worth reading twice is `users/{uid}` accessed by that same uid.
// That is the one a future reader will assume is allowed. It is not, and it
// must not become allowed by accident.

import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import {
  assertFails,
  type RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  limit,
  query,
  setDoc,
  updateDoc,
} from "firebase/firestore";
import {
  CALLERS,
  OTHER_UID,
  UID,
  everyAllowIsDenied,
  makeTestEnv,
  rulesSource,
} from "./helpers";

let env: RulesTestEnvironment;

/** [label, document path, its parent collection path] */
const DOCS = [
  ["the caller's own user document", `users/${UID}`, "users"],
  ["another user's document", `users/${OTHER_UID}`, "users"],
  ["the caller's own event", `users/${UID}/events/evt-1`, `users/${UID}/events`],
  ["reference data", "refdata/cycle-phases", "refdata"],
  // Activation and password-reset tokens (#6). Only the API ever touches them, and a
  // client that could read one could open somebody's account.
  ["an activation token", "authTokens/deadbeef", "authTokens"],
  ["an arbitrary path", "anything/at-all", "anything"],
  ["a deeply nested arbitrary path", "a/b/c/d", "a/b/c"],
] as const;

beforeAll(async () => {
  env = await makeTestEnv();
  await env.clearFirestore();

  // Seed real documents with rules off, so the read tests prove that existing
  // data is unreachable — not merely that missing documents come back empty.
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    for (const [, path] of DOCS) {
      await setDoc(doc(db, path), { seeded: true });
    }
  });
});

afterAll(async () => {
  await env?.cleanup();
});

describe("firestore.rules denies", () => {
  for (const [callerLabel, makeCaller] of CALLERS) {
    describe(callerLabel, () => {
      for (const [docLabel, path, collectionPath] of DOCS) {
        describe(docLabel, () => {
          const db = () => makeCaller(env).firestore();

          test("get", async () => {
            await assertFails(getDoc(doc(db(), path)));
          });

          test("list", async () => {
            await assertFails(
              getDocs(query(collection(db(), collectionPath), limit(1))),
            );
          });

          test("create", async () => {
            await assertFails(setDoc(doc(db(), `${path}-new`), { x: 1 }));
          });

          test("overwrite", async () => {
            await assertFails(setDoc(doc(db(), path), { x: 1 }));
          });

          test("update", async () => {
            await assertFails(updateDoc(doc(db(), path), { x: 1 }));
          });

          test("delete", async () => {
            await assertFails(deleteDoc(doc(db(), path)));
          });
        });
      }
    });
  }
});

test("firestore.rules has no rule allowing anything", () => {
  expect(everyAllowIsDenied(rulesSource("firestore.rules"))).toEqual([]);
});
