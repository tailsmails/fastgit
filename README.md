# FastGit

FastGit is a command-line tool written in V, designed to automate and simplify uploading, syncing, and modifying GitHub repositories without leaving a persistent local Git history or directory. 

By utilizing remote-tree comparison and temporary directory structures, FastGit allows you to push changes, rollback last commits, or remove intermediate commits while keeping your local workspace clean.

---

## Features

### 1. Remote-First Change Comparison
- **File Verification**: Compares local files against the remote repository state using GitHub's recursive Tree API (`GET /git/trees/{branch}?recursive=1`).
- **Standard SHA-1 Hashing**: Calculates file checksums locally matching the Git standard format (`blob <content-length>\0<content>`) as direct byte streams to verify changes before doing any local Git actions.
- **Private Repo Support**: Uses Bearer Token authorization headers to fetch the remote file tree safely, even for private repositories.

### 2. Isolated Git Transactions
- **No Parent Directory Interference**: Restricts Git checks strictly to the target folder, preventing Git directories in parent folders (such as home directories) from interfering with your project.
- **Temporary Repository**: Automatically initializes a temporary Git directory if no local `.git` exists, synchronizes index history using a shallow fetch (`git fetch --depth 1`), and runs your pushes.
- **Automatic Cleanup**: Registers a cleanup routine inside V's `defer` block to automatically delete the temporary `.git` folder (via `rm -rf`) after execution, whether the process succeeds or fails.

### 3. Surgical History Operations
- **Remote Rollbacks (`ctrlz`)**: Undo actions by fetching the latest commits, resetting HEAD locally, and force-pushing to remove the last commit from GitHub.
- **Specific Commit Removal (`remove`)**: Deletes a specific intermediate commit from history using `git rebase --onto`.
- **Root-Commit Handling**: If you delete the first/only commit, FastGit creates an empty commit using `git read-tree --empty` to safely wipe all remote files. If there are multiple commits, it automatically converts the second commit into the new root.

### 4. Anonymity & Evasion Options
- **URL Translation**: Converts SSH URLs (e.g. `git@github.com:...`) to token-authenticated HTTPS URLs to prevent local SSH keys from being exposed on egress traffic.
- **Identity Override**: Rewrites the temporary repository's `user.name` and `user.email` dynamically before making commits.
- **Delta Control (`--lazy`)**: Pushing with `-lazy` or `--lazy` triggers `git add --ignore-removal`, preserving remote files that are not present in your local directory.

---

## Quick Start

```bash
pkg update -y && pkg install -y git clang make && if ! command -v v >/dev/null 2>&1; then git clone --depth=1 https://github.com/vlang/v && cd v && make && ./v symlink && cd ..; fi && git clone --depth=1 https://github.com/tailsmails/fastgit && cd fastgit && v -prod fastgit.v -o fastgit && ln -sf $(pwd)/fastgit $PREFIX/bin/fastgit
```

---

## Usage

### 1. Pushing Changes

**Standard Push (Deletes remote files that are not present locally):**
```bash
./fastgit https://github.com/owner/repo "initial commit" ./my_folder -b main
```

**Lazy Push (Only add/update local files, preserve other remote files):**
```bash
./fastgit https://github.com/owner/repo "lazy update" ./my_folder -b main --lazy
```

**Force Push (Overwrites remote history completely):**
```bash
./fastgit over https://github.com/owner/repo "overwrite state" ./my_folder -b main
```

---

### 2. History Rewriting

**Rollback/Undo Last Remote Commit (`ctrlz`):**
```bash
./fastgit ctrlz https://github.com/owner/repo -b main
```

**Remove a Specific Commit from Remote History:**
```bash
./fastgit remove https://github.com/owner/repo 325c31da0b33da8d994ed6a2f03c99af7b23b0ba -b main
```

---

### 3. Sync & Pull Requests

**Fork a Repository:**
```bash
./fastgit fork https://github.com/upstream/repo
```

**Sync Fork with Upstream:**
```bash
./fastgit sync https://github.com/upstream/repo main
```

**Create a Pull Request:**
```bash
./fastgit pr https://github.com/upstream/repo "PR Title" main
```

---

## Safety & Content Shield (`fastgit_block`)

FastGit actively scans your staged/changed files **before** any Git transaction takes place using a local rules file named `fastgit_block`. If any block rules are violated, the push is aborted instantly [3]. If ignore rules are matched, those files are filtered out of the push transaction quietly.

The validation file supports three distinct modes depending on how you structure it:

### 1. Global Block & Ignore Mode (Default)
If you do not define specific target files, FastGit operates globally. It supports two operations for both filenames and file content:
- **Block (`+`)**: Halts and **aborts** the entire push transaction if a match is found.
- **Exclude (`-`)**: Silently **skips** matched files from the upload list and proceeds with the rest of the transaction without throwing any errors (acting like a content-aware, regex-powered `.gitignore`).

#### Supported Patterns:
*   **`filename + <regex>`**: Aborts the upload if the filename matches.
*   **`filename - <regex>`**: Silently excludes the matched file from the upload.
*   **`file + <regex>`**: Scans contents and aborts the push on any match (e.g., preventing AWS/GitHub token leaks).
*   **`file - <regex>`**: Scans contents and silently excludes matched files from the upload list.

**Example `fastgit_block` (Block & Ignore):**
```ini
# --- SECURITY BLOCK RULES (Aborts Push on Match) ---
# Prevent uploading certificates or config files
filename + \.pem$
filename + config\.json$

# Prevent leaking AWS secrets
file + AWS_SECRET_ACCESS_KEY


# --- SILENT IGNORE RULES (Proceeds but skips the file) ---
# Silently skip log files and editor swap files
filename - \.log$
filename - ~.*$

# Silently skip files containing private flags
file - //\s*@local-only
```

---

### 2. Strict Whitelist Mode
If you define one or more explicit local file paths using `file + <path/to/file>`, FastGit automatically switches to **Strict Whitelist Mode**. 

In this mode:
*   **Only** the explicitly declared files are allowed to be uploaded. Pushing any other modified or untracked files will fail with a whitelist violation error.
*   You can nest specific regular expressions under each whitelisted file to restrict blocked patterns *only* inside those permitted files.

**Example `fastgit_block` (Whitelist):**
```ini
# Only the following two files are allowed to be modified and pushed
file + ./src/main.go
  # Inside main.go, block hardcoded local IP addresses
  file + 127\.0\.0\.1

file + ./src/index.js
  # Inside index.js, block test functions
  file + function\s+test
```

---

## Threat & Isolation Model

| Threat Vector | Mechanism | FastGit Strategy |
| :--- | :--- | :--- |
| **SSH Key Metadata Leak** | Pushing via SSH uses local keys, which can reveal your GitHub identity. | **URL Redirect** translates SSH paths to token-authenticated HTTPS URLs. |
| **Parent Folder Conflict** | Upward lookup of `.git` folder binds to higher directories (like home folders). | **Local Isolation** checks only the immediate target directory for `.git`. |
| **Persistent Configuration Leak** | Commits and configs are stored inside local project folders. | **Teardown** deletes the temporary `.git` folder immediately upon program exit. |
| **Accidental File Exposure** | Orphan branch checkouts might stage unwanted local files. | **Clean Index** empties the Git staging index via `git read-tree --empty` before committing empty states. |

---

## License
![License](https://img.shields.io/badge/License-MIT-green.svg)