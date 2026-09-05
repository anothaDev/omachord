import QtQuick
import Quickshell
import "Conditions.js" as Conditions

ShellRoot {
  id: root
  Service { id: service }
  Panel { id: panel }

  function check(condition, message) {
    if (!condition) throw new Error(message)
  }

  Timer {
    interval: 600
    running: true
    onTriggered: {
      try {
        var ids = ["constructor", "prototype", "tostring", "valueof", "hasownproperty", "tolocalestring"]
        for (var i = 0; i < ids.length; i++) {
          var id = ids[i]
          root.check(service.isRoutineId(id), "valid routine ID was rejected: " + id)
          var routine = { id: id, name: "Routine " + id, enabled: true, triggers: [],
            conditions: [{ type: "omarchy-toggle", flag: "match" }], actions: [{ type: "delay", milliseconds: 0 }] }
          var config = { version: 1, routines: [routine] }
          service.applyConfig({ ok: true, committed: true, revision: "revision", config: config })
          service.applyToggles(["match"])
          service.applyActive([], 100000)
          service.unlatch(id)
          var summary = JSON.parse(service.statusJson()).routines[0]
          root.check(!summary.active && !summary.latched && summary.failure === null, "inherited active/latch/failure: " + id)
          root.check(service.routineMeta[id].name === routine.name, "routine metadata lost: " + id)
          service.latch(id)
          root.check(JSON.parse(service.statusJson()).routines[0].latched, "latch lost: " + id)
          service.unlatch(id)
          root.check(!JSON.parse(service.statusJson()).routines[0].latched, "unlatch left inherited state: " + id)
          service.latchesSeeded = false
          service.applyLogs([{ routineId: id, timestamp: new Date().toISOString(), trigger: "manual", status: "deactivated" }])
          root.check(JSON.parse(service.statusJson()).routines[0].latched, "history did not seed literal ID: " + id)
          service.unlatch(id)
          service.currentJob = { id: id, op: "activate", revision: "revision" }
          service.finishJob('{"ok":false,"error":"fixture failure"}', 1)
          root.check(service.failures[id].error === "fixture failure", "failure record lost: " + id)
          service.applyConfig({ ok: true, committed: true, revision: "new-revision", config: config })
          summary = JSON.parse(service.statusJson()).routines[0]
          root.check(!summary.latched && summary.failure === null, "revision clone retained stale failure: " + id)
          var record = { routineId: id, trigger: "condition", keepUntil: "conditions", setterCount: 1 }
          service.applyActive([record], 100000)
          root.check(service.activeList.length === 1 && service.activeList[0].name === routine.name, "active list lost ID: " + id)
          root.check(service.buildActiveList(service.active, {})[0].name === id, "inherited metadata replaced fallback name: " + id)
          service.currentJob = { id: id, op: "deactivate", revision: "new-revision" }
          service.finishJob('{"ok":true}', 0)
          root.check(service.activeList.length === 0, "optimistic removal lost ID: " + id)
          service.applyActive([record], -1)
          root.check(service.activeList.length === 0, "stale active reply restored ID: " + id)
          service.applyActive([], 100000)
          var worker = { job: null, startPending: false, running: false, command: [] }
          var job = { id: id, op: "run", source: "manual", revision: service.configRevision }
          service.startManualRoutine(worker, job)
          root.check(service.routineBusy(id) && worker.command[2] === id, "literal manual job map lost ID: " + id)
          service.finishManualRoutine(worker, '{"ok":true}', 0)
          root.check(service.routineBusy(id), "manual settling lost ID: " + id)
          service.settleManualActive(100000)
          root.check(!service.routineBusy(id), "manual settling never cleared: " + id)
          panel.config = config
          panel.rebuildActiveIds([])
          root.check(!panel.activeIds[id] && panel.activeRows.length === 0, "panel displays inherited active state: " + id)
          panel.rebuildActiveIds([record])
          root.check(panel.activeRows.length === 1 && panel.activeRows[0].name === routine.name, "panel active row lost ID: " + id)
        }
        var hostile = JSON.parse('{"__proto__":{"routineId":"__proto__","trigger":"manual"}}')
        service.applyActive([hostile.__proto__], 100000)
        panel.rebuildActiveIds([hostile.__proto__])
        root.check(service.activeList.length === 1 && service.activeList[0].id === "__proto__", "active map treated literal __proto__ as a setter")
        root.check(panel.activeRows.length === 1 && panel.activeRows[0].id === "__proto__", "panel map treated literal __proto__ as a setter")
        var inherited = Object.create({ inherited: { routineId: "inherited" } })
        root.check(service.buildActiveList(inherited, {}).length === 0, "service enumerated inherited records")
        root.check(panel.buildActiveRows(inherited, panel.config).length === 0, "panel enumerated inherited records")
        root.check(Object.keys(service.buildManualPendingIds([], inherited, inherited)).length === 0, "manual jobs enumerated inherited records")
        root.check(!service.isRoutineId("__proto__"), "map hardening relaxed ID admission")
        root.check(!service.isRoutineId("toString"), "map hardening relaxed lowercase ID admission")
        console.log("OMACHORD_QML_TEST_PASS", "literal routine ID maps")
      } catch (error) {
        console.error("OMACHORD_QML_TEST_FAIL", String(error))
      }
      Qt.quit()
    }
  }
}
