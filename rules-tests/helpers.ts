// Shared setup for the rules suites.
//
// These tests exist to prove a negative: that `firestore.rules` and
// `storage.rules` deny everything, to every caller. The rules are deny-all *by
// design* — the iOS app never touches Firebase, and the Admin SDK bypasses
// rules entirely (docs/ARCHITECTURE.md §2). Nothing else in the repo notices if
// that stops being true, so this suite is the alarm.
//
// It runs entirely against the emulators: no real project, no credentials.

import { readFileSync } from "node:fs";
import {
  initializeTestEnvironment,
  type RulesTestContext,
  type RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import { setLogLevel } from "firebase/app";

// A `demo-` prefix is firebase-tools' contract for "emulator only": the CLI
// never reaches the network for it and never asks for credentials.
export const PROJECT_ID = "demo-eva-rules";

export const UID = "alice-uid";
export const OTHER_UID = "bob-uid";

export function rulesSource(file: string): string {
  return readFileSync(new URL(`../${file}`, import.meta.url), "utf8");
}

export async function makeTestEnv(): Promise<RulesTestEnvironment> {
  // Every assertion in this suite provokes a PERMISSION_DENIED, and the SDK
  // logs each one at error level. That is the expected outcome here, so mute it
  // and let the test runner's output be the signal.
  setLogLevel("silent");

  // Rules are read from the repo files rather than trusting whatever the
  // emulator loaded from firebase.json, so the suite asserts against the
  // committed source.
  return initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {
      rules: rulesSource("firestore.rules"),
      host: "127.0.0.1",
      port: 8080,
    },
    storage: {
      rules: rulesSource("storage.rules"),
      host: "127.0.0.1",
      port: 9199,
    },
  });
}

/**
 * Every caller shape a real client could present. If any of these gets through,
 * the rules are open.
 *
 * The factories take the environment as an argument because Bun evaluates
 * `describe` bodies before `beforeAll` runs — capturing the variable here would
 * capture `undefined`.
 */
export const CALLERS: ReadonlyArray<
  readonly [string, (env: RulesTestEnvironment) => RulesTestContext]
> = [
  ["an unauthenticated client", (env) => env.unauthenticatedContext()],
  ["a signed-in client", (env) => env.authenticatedContext(UID, {})],
  [
    "a signed-in client with generous claims",
    (env) =>
      env.authenticatedContext(UID, { admin: true, email_verified: true }),
  ],
];

/**
 * A static tripwire alongside the behavioural tests: every `allow` in the file
 * must be conditioned on a literal `false`. Catches a permissive rule on a path
 * the behavioural tests happen not to name.
 */
export function everyAllowIsDenied(source: string): string[] {
  const conditions = [...source.matchAll(/allow[^:;{}]*:\s*if\s+([^;]+);/g)].map(
    (m) => m[1]!.trim(),
  );
  if (conditions.length === 0) return ["no `allow ...: if ...;` rule found"];
  return conditions.filter((c) => c !== "false");
}
