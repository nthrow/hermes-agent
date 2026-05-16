import type { MouseTrackingMode } from '@hermes/ink'

const truthy = (v?: string) => /^(?:1|true|yes|on)$/i.test((v ?? '').trim())

export const STARTUP_RESUME_ID = (process.env.HERMES_TUI_RESUME ?? '').trim()
export const STARTUP_QUERY = (process.env.HERMES_TUI_QUERY ?? '').trim()
export const STARTUP_IMAGE = (process.env.HERMES_TUI_IMAGE ?? '').trim()
// Default to the maximal preset for back-compat; HERMES_TUI_DISABLE_MOUSE
// keeps its kill-switch semantics. Per-mode selection comes from
// display.mouse_tracking in config.yaml (`off|wheel|buttons|all`).
export const MOUSE_TRACKING: MouseTrackingMode = truthy(process.env.HERMES_TUI_DISABLE_MOUSE) ? 'off' : 'all'
export const NO_CONFIRM_DESTRUCTIVE = truthy(process.env.HERMES_TUI_NO_CONFIRM)

// Skip AlternateScreen — TUI renders into the primary buffer so the host
// terminal's native scrollback captures whatever scrolls off the top.
// Experiment gate: lets us measure native scroll vs our virtualization on
// the same pipeline.
export const INLINE_MODE = truthy(process.env.HERMES_TUI_INLINE)

// Live FPS counter overlay, fed by ink's onFrame (real render rate, not a
// synthetic timer).
export const SHOW_FPS = truthy(process.env.HERMES_TUI_FPS)
