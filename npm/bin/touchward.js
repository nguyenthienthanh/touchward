#!/usr/bin/env node
// Installer shim for Touchward, a macOS app.
//
// The app itself is Swift and ships as a signed .app inside a disk image; npm is only a
// convenient way to fetch and place it. Nothing here runs the app — it downloads the
// release asset, checks it against the checksum published with this package, and copies
// the bundle into /Applications.
//
// Installation is an explicit command rather than a postinstall hook on purpose: dropping
// an app into /Applications as a side effect of `npm install` is not something a package
// should do behind your back.

import { createWriteStream } from "node:fs";
import { mkdtemp, rm, readFile, access } from "node:fs/promises";
import { createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { pipeline } from "node:stream/promises";
import { Readable } from "node:stream";

const run = promisify(execFile);
const here = dirname(fileURLToPath(import.meta.url));

const APP = "Touchward.app";
const TARGET = `/Applications/${APP}`;

async function manifest() {
  return JSON.parse(await readFile(join(here, "..", "release.json"), "utf8"));
}

function die(msg) {
  console.error(`✗ ${msg}`);
  process.exit(1);
}

function requireMacOS() {
  if (process.platform !== "darwin") {
    die(`Touchward is a macOS app; this is ${process.platform}. Nothing to install.`);
  }
}

async function download(url, dest) {
  const res = await fetch(url, { redirect: "follow" });
  if (!res.ok) die(`Download failed: HTTP ${res.status} for ${url}`);
  await pipeline(Readable.fromWeb(res.body), createWriteStream(dest));
}

async function sha256(file) {
  const h = createHash("sha256");
  h.update(await readFile(file));
  return h.digest("hex");
}

async function install() {
  requireMacOS();
  const { version, url, sha256: expected } = await manifest();

  const work = await mkdtemp(join(tmpdir(), "touchward-"));
  const dmg = join(work, "Touchward.dmg");
  const mount = join(work, "mnt");

  try {
    console.log(`▸ Downloading Touchward ${version}…`);
    await download(url, dmg);

    console.log("▸ Verifying checksum…");
    const actual = await sha256(dmg);
    if (actual !== expected) {
      die(`Checksum mismatch.\n  expected ${expected}\n  got      ${actual}\nRefusing to install.`);
    }

    console.log("▸ Mounting the disk image…");
    await run("hdiutil", ["attach", dmg, "-nobrowse", "-quiet", "-mountpoint", mount]);

    try {
      // -R replaces any previous copy; TCC keys its grants to the path and signature, so
      // installing over the same location keeps an existing Accessibility grant intact.
      console.log(`▸ Installing to ${TARGET}…`);
      await run("cp", ["-R", join(mount, APP), "/Applications/"]).catch((e) => {
        die(`Could not copy into /Applications — ${e.message.trim()}\nTry: sudo npx touchward install`);
      });
    } finally {
      await run("hdiutil", ["detach", mount, "-quiet"]).catch(() => {});
    }

    console.log(`\n✓ Installed ${TARGET}`);
    console.log(`
Next, grant the one permission it needs:

  System Settings → Privacy & Security → Accessibility → enable Touchward

That also covers reading the touch panel, so Touchward will not show up under
Input Monitoring. That is expected — do not go looking for it there.

Then:  open -a Touchward
`);
  } finally {
    await rm(work, { recursive: true, force: true });
  }
}

async function uninstall() {
  requireMacOS();
  try {
    await access(TARGET);
  } catch {
    console.log(`Nothing to remove — ${TARGET} is not there.`);
    return;
  }
  await run("rm", ["-rf", TARGET]).catch((e) => die(`Could not remove ${TARGET} — ${e.message.trim()}`));
  console.log(`✓ Removed ${TARGET}`);
  console.log("The Accessibility grant stays in System Settings; remove it there if you want it gone.");
}

async function main() {
  const cmd = process.argv[2];
  if (cmd === "install") return install();
  if (cmd === "uninstall") return uninstall();
  if (cmd === "version" || cmd === "--version" || cmd === "-v") {
    return console.log((await manifest()).version);
  }

  const { version } = await manifest();
  console.log(`Touchward ${version} — turns a USB touchscreen into an absolute pointing device on macOS.

This npm package is an installer, not the app. It fetches the signed disk image
from GitHub Releases, checks it against a pinned checksum, and copies the bundle
into /Applications.

  npx touchward install      download, verify and install into /Applications
  npx touchward uninstall    remove /Applications/${APP}
  npx touchward version      the app version this package installs

Alternatives, if you would rather not go through npm:
  brew install --cask nguyenthienthanh/tap/touchward
  https://github.com/nguyenthienthanh/touchward/releases/latest
`);
}

main().catch((e) => die(e?.stack || String(e)));
