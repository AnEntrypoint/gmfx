
import { spawnSync } from "node:child_process";
import { readdirSync } from "node:fs";
import { resolve } from "node:path";



export const nativePackages = {
  "linux-x64": "@libfx/libfx-linux-x64-gnu",
  "linux-arm64": "@libfx/libfx-linux-arm64-gnu",
  "darwin-x64": "@libfx/libfx-darwin-x64",
  "darwin-arm64": "@libfx/libfx-darwin-arm64",
};


export const localNativePackage = nativePackages[`${process.platform}-${process.arch}`];


export function nativeDirArgument(argv = process.argv) {
  const index = argv.indexOf("--native-dir");
  if (index < 0) return null;
  if (!argv[index + 1]) throw new Error("--native-dir needs a directory of platform package tarballs");
  return resolve(argv[index + 1]);
}


export function tarballManifest(path) {
  const listing = spawnSync("tar", ["-xzOf", path, "package/package.json"], { encoding: "utf8" });
  if (listing.status !== 0) throw new Error(`cannot read the manifest in ${path}: ${listing.stderr}`);
  return JSON.parse(listing.stdout);
}


export function nativeTarballs(dir) {
  return Object.fromEntries(readdirSync(dir).filter((name) => name.endsWith(".tgz")).sort()
    .map((name) => [tarballManifest(resolve(dir, name)).name, resolve(dir, name)]));
}



export function localNativeTarball(dir) {
  const tarball = nativeTarballs(dir)[localNativePackage];
  if (!tarball) throw new Error(`${dir} has no ${localNativePackage} tarball`);
  return tarball;
}
