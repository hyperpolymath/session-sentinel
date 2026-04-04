// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Session Sentinel — Structural Validation Test Suite
//
// This is a container/infrastructure repo with no compiled source code.
// CRG Grade C for this repo category means validating structural invariants:
// required files exist, configuration is syntactically valid, placeholders
// are resolved, security fields are present, and no secrets leak.
//
// Test categories:
//   UNIT       — individual file existence checks
//   SMOKE      — basic content sanity (non-empty, correct type)
//   P2P        — property: all TOML files parse without error
//   E2E        — chain: file discovery → content check → field validation
//   CONTRACT   — required fields in each config file
//   ASPECT     — no secrets or tokens in config files
//   BENCHMARK  — directory scan timing

import { assertEquals, assertExists, assert } from "jsr:@std/assert@1";
import { join } from "jsr:@std/path@1";

// Repository root — resolved relative to this test file's location.
const REPO_ROOT = new URL("../", import.meta.url).pathname;

// ====================================================================
// UNIT: Required files exist
// ====================================================================

Deno.test("unit: README.adoc exists", () => {
  const stat = Deno.statSync(join(REPO_ROOT, "README.adoc"));
  assert(stat.isFile, "README.adoc must be a regular file");
});

Deno.test("unit: LICENSE exists", () => {
  const stat = Deno.statSync(join(REPO_ROOT, "LICENSE"));
  assert(stat.isFile, "LICENSE must be a regular file");
});

Deno.test("unit: Containerfile exists", () => {
  const stat = Deno.statSync(join(REPO_ROOT, "Containerfile"));
  assert(stat.isFile, "Containerfile must exist (not Dockerfile)");
});

Deno.test("unit: config/session-sentinel.toml exists", () => {
  const stat = Deno.statSync(join(REPO_ROOT, "config", "session-sentinel.toml"));
  assert(stat.isFile, "config/session-sentinel.toml must exist");
});

Deno.test("unit: container/manifest.toml exists", () => {
  const stat = Deno.statSync(join(REPO_ROOT, "container", "manifest.toml"));
  assert(stat.isFile, "container/manifest.toml must exist");
});

Deno.test("unit: .well-known/security.txt exists", () => {
  const stat = Deno.statSync(join(REPO_ROOT, ".well-known", "security.txt"));
  assert(stat.isFile, ".well-known/security.txt must exist (RFC 9116)");
});

// ====================================================================
// UNIT: Required directories exist
// ====================================================================

Deno.test("unit: config/ directory exists", () => {
  const stat = Deno.statSync(join(REPO_ROOT, "config"));
  assert(stat.isDirectory, "config/ must be a directory");
});

Deno.test("unit: container/ directory exists", () => {
  const stat = Deno.statSync(join(REPO_ROOT, "container"));
  assert(stat.isDirectory, "container/ must be a directory");
});

Deno.test("unit: docs/ directory exists", () => {
  const stat = Deno.statSync(join(REPO_ROOT, "docs"));
  assert(stat.isDirectory, "docs/ must be a directory");
});

// ====================================================================
// SMOKE: Files have non-zero content
// ====================================================================

Deno.test("smoke: README.adoc is non-empty", () => {
  const content = Deno.readTextFileSync(join(REPO_ROOT, "README.adoc"));
  assert(content.length > 0, "README.adoc must not be empty");
});

Deno.test("smoke: LICENSE is non-empty", () => {
  const content = Deno.readTextFileSync(join(REPO_ROOT, "LICENSE"));
  assert(content.length > 0, "LICENSE must not be empty");
});

Deno.test("smoke: config/session-sentinel.toml is non-empty", () => {
  const content = Deno.readTextFileSync(
    join(REPO_ROOT, "config", "session-sentinel.toml")
  );
  assert(content.length > 0, "session-sentinel.toml must not be empty");
});

// ====================================================================
// P2P: Property — all TOML files are syntactically valid
//
// Deno has a built-in TOML parser since 2.x. We enumerate all .toml
// files in the repo and verify each parses without error.
// ====================================================================

import { parse as parseTOML } from "jsr:@std/toml@1";

/** Recursively collects all .toml file paths under a directory. */
function collectTomlFiles(dir: string): string[] {
  const results: string[] = [];
  for (const entry of Deno.readDirSync(dir)) {
    if (entry.name.startsWith(".git")) continue;
    const fullPath = join(dir, entry.name);
    if (entry.isDirectory) {
      results.push(...collectTomlFiles(fullPath));
    } else if (entry.isFile && entry.name.endsWith(".toml")) {
      results.push(fullPath);
    }
  }
  return results;
}

Deno.test("p2p: all TOML files parse without error", () => {
  const tomlFiles = collectTomlFiles(REPO_ROOT);
  assert(tomlFiles.length > 0, "Must have at least one TOML file to validate");

  const errors: string[] = [];
  for (const file of tomlFiles) {
    try {
      const content = Deno.readTextFileSync(file);
      parseTOML(content);
    } catch (err) {
      const relPath = file.replace(REPO_ROOT, "");
      errors.push(`${relPath}: ${err}`);
    }
  }

  assertEquals(
    errors.length,
    0,
    `TOML parse errors:\n${errors.join("\n")}`
  );
});

// ====================================================================
// E2E: Chain — file discovery → TOML parse → field validation
//
// The E2E chain verifies that the complete validation pipeline works
// from file discovery through content parsing to field correctness.
// ====================================================================

Deno.test("e2e: session-sentinel.toml full validation chain", () => {
  // Stage 1: File exists (discovery)
  const configPath = join(REPO_ROOT, "config", "session-sentinel.toml");
  const stat = Deno.statSync(configPath);
  assert(stat.isFile, "E2E stage 1: config file must be discoverable");

  // Stage 2: Content is readable (IO)
  const content = Deno.readTextFileSync(configPath);
  assert(content.length > 0, "E2E stage 2: config file must have content");

  // Stage 3: TOML parses (syntax)
  const config = parseTOML(content) as Record<string, unknown>;
  assertExists(config, "E2E stage 3: TOML must parse to a non-null object");

  // Stage 4: Top-level sentinel section present (structure)
  assert(
    "sentinel" in config,
    "E2E stage 4: config must have [sentinel] section"
  );

  // Stage 5: Required sentinel fields present (contract)
  const sentinel = config.sentinel as Record<string, unknown>;
  assertExists(
    sentinel.scan_interval,
    "E2E stage 5: sentinel.scan_interval must be present"
  );
});

Deno.test("e2e: container manifest full validation chain", () => {
  // Stage 1: Discover
  const manifestPath = join(REPO_ROOT, "container", "manifest.toml");
  assert(Deno.statSync(manifestPath).isFile, "E2E: manifest.toml must exist");

  // Stage 2: Parse
  const content = Deno.readTextFileSync(manifestPath);
  const manifest = parseTOML(content) as Record<string, unknown>;

  // Stage 3: Required metadata fields
  const meta = manifest.metadata as Record<string, unknown>;
  assertExists(meta, "E2E: manifest must have [metadata] section");
  assertExists(meta.name, "E2E: manifest.metadata.name must be present");
  assertExists(meta.version, "E2E: manifest.metadata.version must be present");
  assertExists(meta.license, "E2E: manifest.metadata.license must be present");

  // Stage 4: License correctness
  assertEquals(
    meta.license,
    "PMPL-1.0-or-later",
    "E2E: manifest license must be PMPL-1.0-or-later"
  );
});

// ====================================================================
// CONTRACT: Required fields in config files
// ====================================================================

Deno.test("contract: session-sentinel.toml has required sentinel fields", () => {
  const content = Deno.readTextFileSync(
    join(REPO_ROOT, "config", "session-sentinel.toml")
  );
  const config = parseTOML(content) as Record<string, unknown>;
  const sentinel = config.sentinel as Record<string, unknown>;

  assertExists(sentinel, "contract: [sentinel] section must exist");
  assertExists(sentinel.scan_interval, "contract: scan_interval required");
  assertExists(
    sentinel.enable_self_healing,
    "contract: enable_self_healing required"
  );
  assertExists(sentinel.log_path, "contract: log_path required");
});

Deno.test("contract: security.txt has required RFC 9116 fields", () => {
  const content = Deno.readTextFileSync(
    join(REPO_ROOT, ".well-known", "security.txt")
  );
  assert(content.includes("Contact:"), "contract: security.txt must have Contact field");
  assert(content.includes("Expires:"), "contract: security.txt must have Expires field");
  assert(
    content.includes("Preferred-Languages:"),
    "contract: security.txt must have Preferred-Languages field"
  );
});

Deno.test("contract: container/manifest.toml has required security section", () => {
  const content = Deno.readTextFileSync(
    join(REPO_ROOT, "container", "manifest.toml")
  );
  const manifest = parseTOML(content) as Record<string, unknown>;
  assertExists(manifest.security, "contract: manifest must have [security] section");
  const security = manifest.security as Record<string, unknown>;
  assertExists(security.user, "contract: security.user required");
  assertExists(
    security.no_new_privileges,
    "contract: security.no_new_privileges required"
  );
});

// ====================================================================
// ASPECT: No secrets or API tokens in config files
//
// Scans all TOML and text config files for patterns that indicate
// hardcoded secrets, tokens, or credentials.
// ====================================================================

/** Returns true if the string appears to contain a secret pattern. */
function containsSecretPattern(content: string): boolean {
  const secretPatterns = [
    /(?:api_key|apikey|api-key)\s*=\s*["'][^"']{8,}["']/i,
    /(?:password|passwd|pwd)\s*=\s*["'][^"']{4,}["']/i,
    /(?:secret|token)\s*=\s*["'][a-zA-Z0-9+/]{20,}["']/i,
    /-----BEGIN (?:RSA |EC )?PRIVATE KEY-----/,
    /(?:AWS|AZURE|GCP)_(?:SECRET|KEY|TOKEN)\s*=/i,
    // Hex secrets (32+ chars) but not hex colour codes
    /(?:secret|key|token)\s*=\s*["'][0-9a-f]{32,}["']/i,
  ];
  return secretPatterns.some((pattern) => pattern.test(content));
}

Deno.test("aspect: no hardcoded secrets in config/session-sentinel.toml", () => {
  const content = Deno.readTextFileSync(
    join(REPO_ROOT, "config", "session-sentinel.toml")
  );
  assert(
    !containsSecretPattern(content),
    "aspect: session-sentinel.toml must not contain hardcoded secrets"
  );
});

Deno.test("aspect: no hardcoded secrets in container TOML files", () => {
  const containerDir = join(REPO_ROOT, "container");
  for (const entry of Deno.readDirSync(containerDir)) {
    if (!entry.name.endsWith(".toml")) continue;
    const content = Deno.readTextFileSync(join(containerDir, entry.name));
    assert(
      !containsSecretPattern(content),
      `aspect: ${entry.name} must not contain hardcoded secrets`
    );
  }
});

Deno.test("aspect: no placeholder text {{REPO}} remains in critical files", () => {
  // manifest.toml intentionally has {{PROJECT_DESCRIPTION}} — we check
  // the specific fields that must be resolved: name, version, license.
  const manifestContent = Deno.readTextFileSync(
    join(REPO_ROOT, "container", "manifest.toml")
  );
  const manifest = parseTOML(manifestContent) as Record<string, unknown>;
  const meta = manifest.metadata as Record<string, unknown>;

  // These specific fields must not be placeholders
  assert(
    !String(meta.name).includes("{{"),
    "aspect: manifest.metadata.name must not be a placeholder"
  );
  assert(
    !String(meta.version).includes("{{"),
    "aspect: manifest.metadata.version must not be a placeholder"
  );
  assert(
    !String(meta.license).includes("{{"),
    "aspect: manifest.metadata.license must not be a placeholder"
  );
});

// ====================================================================
// BENCHMARK: Directory scan timing
//
// Verifies that a full repo scan (used by the property tests above)
// completes within a reasonable time budget. Establishes a baseline.
// ====================================================================

Deno.test("benchmark: full repo TOML scan completes within 2 seconds", () => {
  const start = performance.now();
  const tomlFiles = collectTomlFiles(REPO_ROOT);
  for (const file of tomlFiles) {
    const content = Deno.readTextFileSync(file);
    parseTOML(content);
  }
  const elapsed = performance.now() - start;

  assert(
    elapsed < 2000,
    `benchmark: TOML scan took ${elapsed.toFixed(1)}ms — must be < 2000ms`
  );
  // Log the baseline for future reference (visible in test output)
  console.log(
    `  benchmark: scanned ${tomlFiles.length} TOML files in ${elapsed.toFixed(1)}ms`
  );
});
