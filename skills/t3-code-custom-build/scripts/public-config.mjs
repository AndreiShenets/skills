import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { parseEnv } from "node:util";

const [worktree, repo = worktree] = process.argv.slice(2);
if (!worktree) throw new Error("Supply the build worktree and optional source checkout");

const aliases = {
  T3CODE_CLERK_PUBLISHABLE_KEY: ["VITE_CLERK_PUBLISHABLE_KEY", "EXPO_PUBLIC_CLERK_PUBLISHABLE_KEY"],
  T3CODE_CLERK_JWT_TEMPLATE: ["VITE_CLERK_JWT_TEMPLATE", "EXPO_PUBLIC_CLERK_JWT_TEMPLATE"],
  T3CODE_CLERK_CLI_OAUTH_CLIENT_ID: ["VITE_CLERK_CLI_OAUTH_CLIENT_ID"],
  T3CODE_RELAY_URL: ["VITE_T3CODE_RELAY_URL"],
};
const files = [
  resolve(worktree, ".env.local"),
  resolve(worktree, ".env"),
  resolve(repo, ".env.local"),
  resolve(repo, ".env"),
  resolve(worktree, ".env.example"),
];
const sources = [process.env, ...[...new Set(files)].map((file) =>
  existsSync(file) ? parseEnv(readFileSync(file, "utf8")) : {},
)];
const config = {};
for (const [key, alternatives] of Object.entries(aliases)) {
  const names = [key, ...alternatives];
  const value = sources.flatMap((source) => names.map((name) => source[name]?.trim())).find(Boolean);
  if (!value || /[\r\n\0]/u.test(value)) throw new Error(`Missing or invalid public Connect configuration: ${key}`);
  config[key] = value;
}
if (!/^pk_(live|test)_[A-Za-z0-9_=-]+$/u.test(config.T3CODE_CLERK_PUBLISHABLE_KEY)) {
  throw new Error("Invalid T3CODE_CLERK_PUBLISHABLE_KEY");
}
try {
  const relay = new URL(config.T3CODE_RELAY_URL);
  if (relay.protocol !== "https:" || relay.username || relay.password) throw new Error();
} catch {
  throw new Error("Invalid T3CODE_RELAY_URL: use a public HTTPS URL");
}
console.log(JSON.stringify(config));
