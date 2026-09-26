import fs from "node:fs"
import vm from "node:vm"
import assert from "node:assert/strict"

// Read the real implementation without altering it or depending on QML.
const source = fs.readFileSync(new URL("../../Conditions.js", import.meta.url), "utf8")
const conditions = {}
vm.createContext(conditions)
vm.runInContext(source, conditions)
assert.equal(typeof conditions.reconcileJobs, "function")
assert.equal(typeof conditions.describeFailure, "function")

assert.equal(process.argv.length, 3, "usage: node conditions-conformance.mjs LEAN_OUTPUT")
const vectors = fs.readFileSync(process.argv[2], "utf8").split(/\r?\n/)
const bool = value => {
  assert.ok(value === "true" || value === "false", `invalid boolean: ${value}`)
  return value === "true"
}
const integer = value => {
  assert.match(value, /^-?\d+$/)
  const result = Number(value)
  assert.ok(Number.isSafeInteger(result), `not a safe integer: ${value}`)
  return result
}
const seen = new Set()
let retryVectors = 0
let retryChecks = 0
let descriptionVectors = 0
for (const line of vectors) {
  if (!line.startsWith("RETRY ") && !line.startsWith("DESCRIPTION ")) continue
  assert.ok(!seen.has(line), `duplicate vector: ${line}`)
  seen.add(line)
  const fields = line.split(" ")
  if (fields[0] === "RETRY") {
    assert.equal(fields.length, 9, line)
    const [, runningText, presentText, sameOpText, sameRevText, blockedText, op, elapsedText, allowedText] = fields
    const [running, present, sameOp, sameRev, blocked, allowed] =
      [runningText, presentText, sameOpText, sameRevText, blockedText, allowedText].map(bool)
    assert.ok(op === "activate" || op === "deactivate", line)
    const elapsed = integer(elapsedText)
    const otherOp = op === "activate" ? "deactivate" : "activate"
    // Absent job, same id/op, same id/different op, other id/same op.
    const currentJobs = running ? [{ id: "routine", op }] : [null,
      { id: "routine", op: otherOp }, { id: "unrelated", op }]
    for (const at of [0, 1700000000000]) {
      for (const currentJob of currentJobs) {
        const failures = present ? { routine: {
          op: sameOp ? op : otherOp, revision: sameRev ? "revision" : "old-revision", at, blocked
        } } : {}
        const actual = conditions.reconcileJobs([{ id: "routine", op, reason: "condition" }],
          currentJob, "revision", failures, at + elapsed, 300000, 256)
        assert.equal(actual.length, allowed ? 1 : 0, `${line}; at=${at}; current=${JSON.stringify(currentJob)}`)
        if (allowed) {
          assert.deepEqual(JSON.parse(JSON.stringify(actual[0])),
            { id: "routine", op, reason: "condition", revision: "revision" }, line)
        }
        retryChecks++
      }
    }
    retryVectors++
  } else {
    assert.equal(fields.length, 6, line)
    const [, op, blockedText, atText, retryMsText, retryAtText] = fields
    assert.ok(op === "activate" || op === "deactivate", line)
    const blocked = bool(blockedText)
    const at = integer(atText)
    const retryMs = integer(retryMsText)
    const retryAt = retryAtText === "null" ? null : integer(retryAtText)
    const actual = conditions.describeFailure({ op, blocked, at, error: "fixture error" }, retryMs)
    assert.deepEqual(JSON.parse(JSON.stringify(actual)),
      { op, blocked: retryAt === null, at, error: "fixture error", retryAt }, line)
    descriptionVectors++
  }
}
// Fail closed on missing/truncated generator output, including an empty file.
assert.equal(retryVectors, 512, "complete retry vector matrix")
assert.equal(descriptionVectors, 24, "complete description vector matrix")
console.log(`Lean/Conditions.js conformance: ${retryVectors} retry vectors (${retryChecks} checks), ${descriptionVectors} description vectors passed`)
