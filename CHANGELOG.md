# Changelog

## 1.3.0 - 2026-10-20

Claude Desktop (Microsoft Store) moved its data from
`%LOCALAPPDATA%\Packages\Claude_...\LocalCache\Roaming\Claude` to `%LOCALAPPDATA%\Claude-Data\claude_<id>`
and left only a `.user-data-left.*` marker behind. Clones made by earlier versions linked their
`claude-code-sessions` and `claude-code` folders to the old location: the session list in those clones
looked empty and Claude Code sessions could no longer be resumed. The data itself was never lost.
After updating, run `claude-clone.ps1 -Repair` once.

### Fixed (Windows)

- The main profile is looked up at every start (newest folder with a `config.json`, folders with a
  `.user-data-left.*` marker are skipped) instead of the old Microsoft Store path, which still existed
  and was picked even though it was empty.
- New clones no longer create folders inside an outdated location of the main profile.
- `-Repair` only re-created shortcuts and left broken links alone. It now repairs links, launchers, list
  entries and shortcuts - and only touches what is actually broken, saying why.
- "running" matched profile paths by substring (`Claude-work` matched `Claude-work2`) and also
  counted Claude Code processes.
- Re-running create for an existing clone overwrote the clone's own MCP settings.
- Launchers are written with a BOM; paths with umlauts broke under Windows PowerShell 5.1.
- Claude Desktop versions were sorted as text.
- Deleting a profile in OneDrive treated OneDrive placeholders as links.
- The Start menu folder could not be found when the known folder did not exist.
- `-Launch` was not handed over to the bash script on macOS / Linux.

### New

- **Self-repairing launchers.** Before Claude starts, every Desktop launcher repairs dead or outdated
  links in its profile and syncs the session list; a problem is shown as a message. `launch.ps1 -CheckOnly`
  shows what it would do. Everything is logged to `~\.claude-clone\logs`.
- **Session sync instead of a linked session folder.** Each clone keeps its own session list and syncs
  the accounts signed in to it with the main profile (`-SessionSync both|pull|off`, default `both`).
  Never deletes, never brings back a deleted session, only adds to a profile whose window is open.
- **`-Doctor` / `-Repair`** for every profile: dead links, outdated launchers, missing folders, orphaned
  shortcuts, profiles in OneDrive / Dropbox or in AppData, accounts signed in to several clones.
- **Which account is where.** The dashboard shows the main profile with its accounts and session counts,
  the account of every clone, and a health summary. `-NameAccount "<id>=<name>"` names accounts.
- **`-Move`** moves a profile (for example out of OneDrive), compares the copy and updates launcher,
  shortcuts and the list.
- **Sync when closed.** After starting Claude the launcher waits in the background (on the process, no
  polling) and syncs once more when the window is closed, so sessions made in a clone reach the main
  profile right away (`-NoSyncOnExit` turns it off).
- **`-Find`** searches the sessions of the main profile and every clone by title, project folder or id
  and shows the account, the profiles that have the session and when it was last used.
- **`-Backup` / `-Restore`.** Backups of the session lists of the main profile and every clone (read
  while Claude runs, the newest 5 per profile are kept); a restore adds missing sessions and never
  overwrites anything. `-Purge` and `-Move` make a backup first.
- **`-Rename`** renames a clone: folder, launcher, shortcuts, command, log and list entry.
- **`-Update`** gets the newest claude-clone from GitHub (checked before it replaces anything) and
  brings every launcher up to date; the dashboard mentions a new version once a day
  (`CLAUDE_CLONE_NO_UPDATE_CHECK=1` turns that off). **`-Install`** puts claude-clone into
  `~\.claude-clone` with a `claude-clone` command and a Start menu entry.
- Launchers carry a fingerprint of their runtime, so an outdated launcher is noticed even without a
  version change; the "Claude (main)" launcher is checked too.
- **`-Sync`**, **`-Set`** (label, session sync, sync when closed, shared runtime, icon, `-CopySettings`
  to copy the main profile's MCP settings again), **`-Launch main`**, and a settings menu per clone in
  the dashboard.
- Clone icons get a colored letter (`-NoBadge` for the plain icon).
- The clone list is written atomically, the previous version is kept as `clones.json.bak`, and a
  damaged list no longer stops the tool.
- Warning when a clone is started while the main window has the same account open.

### macOS / Linux

- `--doctor` / `--repair`: missing profile folders, dead links, outdated launchers, cloud folders.
- Launchers remove dead links before every start and link the main profile's folders again.
- Warning when profiles are to be stored in a cloud-synced folder.
- Links are only created to folders that exist; nothing is created inside the main profile.
- Empty fields in `clones.tsv` are written as `-`, so the columns can no longer shift.
- Claude Code started with `--launch` no longer gets the clone list as its input.
