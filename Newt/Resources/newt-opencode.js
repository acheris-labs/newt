// Newt — holds your Mac awake while opencode is working.
//
// Installed and removed by Newt (Settings ▸ Integrations). Deleting this file
// is a complete uninstall; nothing else in opencode's configuration is touched.
//
// opencode discovers this by globbing {plugin,plugins}/*.{ts,js} in its config
// directories at startup, so the filename doesn't matter but the default export
// does: a plugin loaded from a path is rejected at load time unless it exports
// both `id` and `server`. (`id` is optional in the published types because an
// npm-installed plugin takes its id from package.json; a file has no package,
// so it must say. The failure is a log line, not anything the user sees.)

const AGENT = "opencode"

// URLComponents.queryItems (Newt's side) does not decode "+" as a space, so
// every value goes through encodeURIComponent for %20. URLSearchParams would
// emit "+" and land project names like "my repo" in the menu as "my+repo".
const claimURL = (params) =>
  "newt://claim?" +
  Object.entries(params)
    .filter(([, v]) => v !== undefined && v !== null && v !== "")
    .map(([k, v]) => `${k}=${encodeURIComponent(v)}`)
    .join("&")

export default {
  id: "newt",
  server: async ({ $, directory, worktree }) => {
    const pid = process.pid
    const label =
      (directory || worktree || "").split("/").filter(Boolean).pop() || AGENT

    // A detached server has no controlling terminal and reports "??"; Newt
    // renders a missing tty as "no tty", which is truer than showing that.
    let tty = ""
    try {
      tty = (await $`ps -o tty= -p ${pid}`.text()).trim()
      if (tty === "??" || tty === "?") tty = ""
    } catch {}

    // Ids we're currently claiming, so shutdown can let go of them and a
    // repeat acquire can be skipped.
    const held = new Set()

    const send = async (params) => {
      // `open -g` leaves Newt in the background; without it every turn would
      // steal focus. A failure here must never take opencode down with it.
      try {
        await $`open -g ${claimURL(params)}`.quiet()
      } catch {}
    }

    const acquire = async (id) => {
      // A stalled request cycles busy → retry → busy, so without this a
      // provider that is down spawns an `open` every few seconds. The claim is
      // dropped on idle at the end of each turn, so the next turn still
      // re-claims — which is what recovers the claim if Newt restarts.
      if (!id || held.has(id)) return
      held.add(id)
      await send({ acquire: "true", id, agent: AGENT, pid, tty, label })
    }

    const release = async (id) => {
      if (!id || !held.delete(id)) return
      await send({ acquire: "false", id })
    }

    return {
      event: async ({ event }) => {
        const p = event.properties
        switch (event.type) {
          case "session.status":
            // "retry" is a stalled request being retried — still working.
            if (p.status?.type === "busy") await acquire(p.sessionID)
            else if (p.status?.type === "idle") await release(p.sessionID)
            break
          case "session.idle":
            await release(p.sessionID)
            break
          case "session.error":
            await release(p.sessionID)
            break
          case "session.deleted":
            await release(p.info?.id)
            break
        }
      },
      // Ordinary shutdown. A kill leaves this unrun, which is what Newt's
      // process watcher and claim limit are for.
      dispose: async () => {
        for (const id of [...held]) await release(id)
      },
    }
  },
}
