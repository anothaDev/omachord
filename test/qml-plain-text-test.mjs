import assert from "node:assert/strict"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const qmlFiles = fs.readdirSync(root).filter(name => name.endsWith(".qml"))
let sinkCount = 0

for (const name of qmlFiles) {
  const lines = fs.readFileSync(path.join(root, name), "utf8").split("\n")
  for (let index = 0; index < lines.length; index++) {
    if (!/^\s*Text\s*\{\s*$/.test(lines[index])) continue
    sinkCount++
    let next = index + 1
    while (next < lines.length && /^\s*(?:\/\/.*)?$/.test(lines[next])) next++
    assert.match(
      lines[next] || "",
      /^\s*textFormat\s*:\s*Text\.PlainText\s*$/,
      `${name}:${index + 1} must declare Text.PlainText before other properties`
    )
  }
}

assert.ok(sinkCount > 0, "expected project-owned Text sinks")
const panel = fs.readFileSync(path.join(root, "Panel.qml"), "utf8")
assert.doesNotMatch(panel, /Button\s*\{[^{}]*text\s*:\s*modelData\.name/s,
  "runtime routine names must not use the shared AutoText button label")
assert.match(panel, /PlainTextButton\s*\{[\s\S]*?plainText\s*:\s*modelData\.name/,
  "runtime routine-name buttons must use PlainTextButton")
console.log(`QML plain-text policy passed for ${sinkCount} Text sinks.`)
