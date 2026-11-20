import fs from "node:fs";
import path from "node:path";
const repo = process.cwd();
const source = path.join(repo, "src/core/parity/item3.zig");
const binary = path.join(repo, "zig-out/bin/fx");
const result = { item: 3, sourcePresent: fs.existsSync(source), binaryBlocked: !fs.existsSync(binary), peers: ["oscraft", "thebird", "spoint", "acptoapi-7b"] };
console.log(JSON.stringify(result));
if (!result.sourcePresent) process.exit(1);
