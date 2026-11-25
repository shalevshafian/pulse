# Codex and MCP: what was found, 25 November 2026

**Status tags**
- [real]: run against the real `~/.codex`.
- [scratch]: probe with a temporary `CODEX_HOME` and network blocked. No auth and no turns, so no model calls.
- [src]: source at tag `rust-v0.170.0`, paths under github.com/openai/codex/tree/rust-v0.170.0/codex-rs.
- [docs]: official docs. `developers.openai.com/codex/*` now redirects to `learn.chatgpt.com/docs/*`.

## A. MCP

**Pulse is connected [real].** `codex mcp get pulse --json` returns rc 0:
- `name`, `enabled:true`, `disabled_reason:null`
- `transport:{type:"stdio",command:"/Applications/Pulse.app/Contents/MacOS/Pulse",args:["--mcp"],env:null,env_vars:[],cwd:null}`
- `enabled_tools`, `disabled_tools`, `startup_timeout_sec` and `tool_timeout_sec`, all null

A missing server gives rc 1. `list --json` adds `auth_status`. `get` and `list` do not print approval mode.

**Fields for `[mcp_servers.<name>]`** ([docs](https://learn.chatgpt.com/docs/extend/mcp?surface=cli), `config/src/mcp_types.rs`):
- Launch: `command`, `args`, `env`, `env_vars`, `cwd`, `environment_id`
- Startup: `enabled`, `required`, `startup_timeout_sec` (10), `startup_readiness`
- Calls: `tool_timeout_sec` (60), `supports_parallel_tool_calls`, `tool_input_schema_max_bytes`, `omit_tools_from`
- Tools: `enabled_tools`, `disabled_tools`, `default_tools_approval_mode`, `tools.<t>.approval_mode`, `tools.<t>.output_token_limit`
- Approval modes: `auto` (default), `prompt`, `writes`, `approve`

**Sharing:** the ChatGPT desktop app, CLI and IDE extension share `~/.codex/config.toml`; project `.codex/config.toml` counts only if trusted [docs].

**`codex mcp add` and `remove` [scratch]**
- They print `Added global MCP server 'pulse'.` and `Removed global…`. There is no `--json` on either. Removing an unknown name is rc 0.
- **`add` is destructive.** It rewrites the whole `mcp_servers` section. My test lost comments in other entries, and `enabled=false` and `default_tools_approval_mode` on the existing entry.
- **Safer official write:** app-server `config/value/write` with `{"keyPath":"mcp_servers.pulse","value":{…},"mergeStrategy":"upsert"}`. It kept all comments and other entries on 0.170.0 and 0.171.0-alpha.13.2. `app-server` is labelled experimental.

**When a session picks it up [scratch 0.170.0]**
- External edit: an already loaded thread says `unknown MCP server`, also after 4 s.
- A new thread in the same server process works at once.
- `config/mcpServer/reload` fixes the old thread, but only inside that process.
- So tell the user "new chats see Pulse; restart the app for open ones" [docs say Restart in the app].

**Protocol [src]:** Codex offers `2025-06-18`. `2026-07-28` exists but is off (`mcp_2026_07_28`, under development) and needs server opt-in. Pulse echoes the version it is offered. That is safe now, but it should answer only versions it knows.

**Annotations [src `core/src/mcp_tool_call.rs:2793`]**
- In `auto`, `readOnlyHint:true` means no prompt. Otherwise missing `destructiveHint` and `openWorldHint` default to true and it prompts.
- `writes` prompts unless read-only.
- The hint is dropped when no client is connected, i.e. for cached catalogs (`tool_catalog.rs:453`).
- With approval policy `never`, a tool that needs approval is denied.
- All 11 Pulse tools send `readOnlyHint:true`. I did not test a model-initiated call.
- Adding `destructiveHint:false` and `openWorldHint:false` avoids the prompt if the read-only hint is dropped.

**Other**
- `structuredContent` replaces text when present, and `outputSchema` is used for the tool's output type [src]. Pulse sends neither, which is fine.
- `instructions` is used; make the first 512 characters self-contained [docs].
- `list_changed` is ignored by default (`mcp_tool_list_changed` off).

**Sandbox:** not applied to MCP processes.
- `system_usage`, `top_memory`, `open_ports`, `sleep_blockers` and `claude_sessions` all returned data in a `sandbox:"read-only"` thread [scratch 0.170.0].
- On the 0.171 alpha bundled binary, the same tools returned data on a default-sandbox thread, launched from a terminal.
- ChatGPT.app's `app-sandbox` entitlement is `false`.
- Env passed: HOME, LOGNAME, PATH, SHELL, USER, LANG, LC_ALL, TERM, TMPDIR, TZ and a few more.
- One Pulse process is spawned **per thread**.

**Binary for a GUI with no PATH**
- `/opt/homebrew/bin/codex` is a Node script. With an empty env it fails: `env: node: No such file`.
- Use in this order, checking each is executable:
  1. `<npm root>/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex` (here under `/opt/homebrew/lib/node_modules`)
  2. `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex` (bundle id `com.openai.codex`; works with empty env)
  3. `~/.codex/packages/standalone/current/…`
  4. `~/.local/bin`, `/usr/local/bin`
- The layout inside 3, the Homebrew cask and Codex.app are UNCONFIRMED here.

## B. Others

- **Claude Code:** `~/.claude.json`. `claude mcp add -s user pulse -- <cmd> --mcp`; check with `claude mcp get pulse` [real: Connected]. Default scope is `local`. `get` has no JSON shown here.
- **Cursor:** `~/.cursor/mcp.json` ([docs](https://cursor.com/docs/context/mcp)). No add command documented. Best is the [deeplink](https://cursor.com/docs/context/mcp/install-links) `cursor://anysphere.cursor-deeplink/mcp/install?name=…&config=<base64 json>`.
- **VS Code:** `code --add-mcp '{"name":…,"type":"stdio","command":…,"args":[…]}'` writes the user profile `mcp.json` ([docs](https://code.visualstudio.com/docs/agents/reference/mcp-configuration)).
- **Gemini CLI:** `gemini mcp add -s user pulse <cmd> …` writes `~/.gemini/settings.json`; default scope is project ([docs](https://raw.githubusercontent.com/google-gemini/gemini-cli/main/docs/tools/mcp-server.md)). How it passes `--mcp` is UNCONFIRMED.
- Cursor, VS Code and Gemini commands are not on this Mac's PATH, so those lines are docs only.

## C. Sessions

### Liveness: writer locks, the best signal found
`~/.codex/thread-writer-locks/<thread-uuid>.lock` is empty and held open by the owning process for as long as the thread is loaded (`rollout/src/writer_lock.rs`).
- [scratch, both versions] One app-server with two threads showed both `.lock` paths in `lsof`, before any rollout existed.
- `thread/archive` released its lock. `thread/unsubscribe` did not, at least after 1 s; docs say an idle unattached thread closes after 30 minutes.
- **After `kill -9` the file stays.** Existence is not liveness; an open descriptor is.
- **Never take the lock to probe.** A second writer fails with `already has an active writer`.
- Undocumented internal interface: medium risk.

### Rollouts
**Files [real]:** 574 `.jsonl` and 3891 `.zst` (cold ones get compressed). The thread id is in the name.

**`session_meta.payload`:** `id`, `session_id`, `parent_thread_id`, `timestamp`, `cwd`, `runtime_workspace_roots`, `originator`, `cli_version`, `source`, `thread_source`, `model_provider`, `history_mode` (`legacy`|`paginated`), `git{…}`, `base_instructions`.
- `originator` seen: `codex_exec`, `Codex Desktop`, `codex_work_desktop`, `T3 Code`, `codex-tui`.
- `source`: `cli`, `vscode`, `exec`, `mcp`, or an object such as `{"subagent":…}`. The desktop app and T3 Code both say `vscode`, so **use `originator`**.

**Turn events** (`event_msg`):
- `task_started{turn_id, started_at}`
- `task_complete{turn_id, completed_at?, duration_ms?}`. Two observed shapes lack `completed_at`; fall back to the line's `timestamp`.
- `turn_aborted{turn_id?, reason, completed_at?}`
- Also `token_count`, `thread_settings_applied` (can be the last line after a completed turn) and `item_completed`.

**Not persisted [src `rollout/src/policy.rs`]:** `ExecApprovalRequest`, `ApplyPatchApprovalRequest`, `RequestPermissions`, `RequestUserInput`, `ElicitationRequest`, `ItemStarted`, `ExecCommandBegin`. **The rollout cannot say "waiting for approval".**
- A pending `function_call` named `request_user_input` with no output likely means waiting for an answer (UNCONFIRMED live, and code-mode calls may hide the name).

**Flush [src]:** items are written and flushed as added (no fsync). The file is not created until first materialized, so a new empty thread has none. Live latency and whether the rollout descriptor stays open are UNCONFIRMED.

**Crash:** 3 of 569 recent files (with any turn event) end on `task_started`, so busy needs a live lock too.

### SQLite (all WAL; `0202`)
- `state_5.sqlite`, `threads`: `id, rollout_path, created_at(_ms), updated_at(_ms), recency_at(_ms), source, cwd, title, name, preview, first_user_message, archived, archived_at, git_branch, cli_version, model, agent_nickname, agent_role, thread_source, history_mode, is_pinned, originator, project_id, attached_thread_parent_id, …`. Also `thread_spawn_edges(parent_thread_id, child_thread_id, status)`.
- **Title:** use `name`, else `title`. `title` may be prompt text (UNCONFIRMED); never read `preview` or `first_user_message`.
- `thread_history_1.sqlite`, `thread_turns(thread_id, turn_id, status, started_at, completed_at, …)`: 59 rows say `inProgress` with nothing running, and the file is 11 GB. Do not use.
- `sqlite/codex.db` (desktop): `local_thread_catalog`, `active_chat_turns`. Private; skip.
- **Open:** a read-only open of `state_5` failed here (no `-wal`/`-shm` present); `immutable=1` worked. If `-wal` exists use `SQLITE_OPEN_READONLY` (short busy timeout), otherwise `immutable=1`. Immutable ignores a live WAL.
- File number (`_5`) and columns change between versions: high risk, so every column must be optional. `sqlite_home` / `CODEX_SQLITE_HOME` can move it.
- `session_index.jsonl` (`id, thread_name, updated_at`) is a lighter title fallback.

### Official status interfaces
- **app-server** ([docs](https://learn.chatgpt.com/docs/app-server)): `thread/status/changed`, `thread/list`, `thread/read`. Status is `notLoaded|idle|systemError|active{activeFlags:[waitingOnApproval|waitingOnUserInput]}`. This is exact, but only for that process: a second app-server's `thread/loaded/list` was empty while the first held two threads [scratch].
- **Daemon:** `~/.codex/app-server-control/app-server-control.sock`, reached by `codex app-server proxy`. Absent now. `daemon.pid` can be stale, and `loaded-threads.json` is only a restart snapshot. `daemon_auto_start` is on in 0.170, so an interactive `codex` may be a thin client of a shared daemon; which pid holds its locks is UNCONFIRMED. Never start the daemon from Pulse.
- **Hooks** ([docs](https://learn.chatgpt.com/docs/hooks)), the most stable push interface: `SessionStart`, `UserPromptSubmit`, `PermissionRequest`, `PostToolUse`, `Stop`, `Interrupt`, `SessionEnd`, with `session_id`, `transcript_path`, `cwd`, `turn_id`.
  - Each needs user trust via `/hooks`, by hash.
  - `PermissionRequest` fires **before** the reviewer, so automatic review also looks like waiting [src `core/src/tools/approvals.rs:602`].
  - Payloads carry prompts and tool input; a helper must discard them.
- **`notify`:** only `agent-turn-complete`, one program at a time. Merge into `hooks.json`, never overwrite.

## Recommended for Pulse

**Connect**
1. Find the native binary; run `mcp get pulse --json`.
2. Same command, args and `enabled`: "Connected". Disabled: ask, do not silently re-enable.
3. Absent or different: spawn `codex app-server`, `initialize`, `initialized`, `config/value/write` on `mcp_servers.pulse`, exit. If that fails, back up and use `mcp add`, only if absent.
4. Verify with `mcp get`. Disconnect with `keyPath` write (null deletion UNCONFIRMED) or `mcp remove`, which rewrites the section like `add`.

**`CodexSession` each refresh**
1. Candidates: processes whose executable is `codex` (include `CodexCLI.app`). List vnode descriptors with `proc_pidinfo(PROC_PIDLISTFDS)` + `PROC_PIDFDVNODEPATHINFO`; match `thread-writer-locks/<uuid>.lock`. Gives (pid, threadId). `lsof` worked same-user; the direct calls from Pulse are untested.
2. Join `threads` by id for `rollout_path`, `cwd`, `name`, `archived`, `source`, `originator`. Fallback: newest rollout whose name ends with the id, first line only.
3. Hide or nest rows with `parent_thread_id`, an object `source`, or `thread_source` `subagent` / `guardian_review`. Show `codex_exec` as a run, not a chat.
4. Scan the rollout backward in growing chunks (start 256 KB; lines can exceed 64 KB) for the last `task_started`/`task_complete`/`turn_aborted`. Started: busy since `started_at`. Otherwise idle since `completed_at` or the line timestamp. No file: idle since lock mtime. Cache by inode and size; drop a partial last line.
5. Waiting: only from the optional hook, cleared by a later `PostToolUse`/`Stop`/`Interrupt` or turn end. Without it, show "busy", perhaps "quiet for N min". Do not guess.
6. Memory: if a pid owns several threads, show the tree once on a process header ("N sessions, shared"). Tool children cannot be reliably attributed to a thread.
7. Cut or fold app threads idle a long time: they stay loaded.
8. Guard pid reuse with start time, as `isLive` does.

**Resume closed:** rows with `archived=0`, not live, `source` `cli` or `vscode`.
- Terminal: `cd <cwd>` then `codex resume <uuid>`. App threads: `codex://threads/<uuid>` (used by the TUI itself, `tui/src/app/history_ui.rs`; scheme registered on this Mac; opening it untested).
- Check the lock again first: an active writer makes resume fail. Archived threads need `codex unarchive <id>`.

## NOT VERIFIED
- Real live Codex turn, desktop process layout, daemon TUI ownership, hooks firing, model-initiated approval, `codex://` opening.
