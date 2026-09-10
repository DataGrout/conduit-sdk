// ESLint flat config (ESLint 9 / typescript-eslint 8).
//
// Scope: the shipped library source only. Tests are deliberately not linted --
// `npm run lint` runs `eslint src`, and tests/ leans on loose stubs (capturing
// WebSocket doubles, injected fetch impls) whose findings would be about test
// scaffolding rather than about shipped code.
//
// Formatting is owned by Prettier, so no stylistic/formatting rules are enabled
// here: this is typescript-eslint's `recommended` set, minus the one rule noted
// below. The non-type-checked variant is intentional -- it needs no TS program,
// so lint stays fast and does not depend on tsconfig include/exclude.

const tseslint = require("@typescript-eslint/eslint-plugin");

module.exports = [
  ...tseslint.configs["flat/recommended"].map((config) => ({
    ...config,
    files: ["src/**/*.ts"],
  })),
  {
    files: ["src/**/*.ts"],
    rules: {
      // Off: 209 findings across 13 files. The client, transports and namespace
      // wrappers pass through arbitrary MCP/JSON-RPC payloads, so typing these
      // out is a real API-design change, not a lint fix. Left as known debt
      // rather than papered over with per-file eslint-disable comments.
      "@typescript-eslint/no-explicit-any": "off",

      // Match tsconfig's noUnusedParameters, which already exempts a leading
      // underscore -- the convention the codebase uses for intentionally unused
      // parameters and catch bindings.
      "@typescript-eslint/no-unused-vars": [
        "error",
        {
          argsIgnorePattern: "^_",
          varsIgnorePattern: "^_",
          caughtErrorsIgnorePattern: "^_",
        },
      ],
    },
  },
];
