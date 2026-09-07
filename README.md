# leetcode-cookie-source

Configurable browser cookie sources for
[leetcode.el](https://github.com/kaiwk/leetcode.el) — the Emacs LeetCode
client you already use.

## Problem

leetcode.el reads your login session with the `my_cookies` tool, which is
built on `browser_cookie3`.  That library:

- does not know the **Zen browser** (Zen profiles live under `~/.config/zen`,
  not `~/.mozilla/firefox`), and
- always returns the first browser jar it finds, even when the session in it
  is stale or invalid.

So when you are logged into LeetCode via Zen (or another browser my_cookies
mishandles), fetching the problem list works (no login required), but
`leetcode-try` / `leetcode-submit` fail.

## What this package does

It overrides leetcode.el's cookie lookup (`leetcode--cookie-get-all`) with an
ordered, **user-configurable chain of cookie sources**.  Each source is either:

| Source | Meaning |
| --- | --- |
| `(:firefox-dir DIR)` | Read cookies directly from the `cookies.sqlite` of any Firefox-family browser profile directory (`DIR`). Works for Zen, LibreWolf, Waterfox, Firefox. |
| `(:command CMD)` | Run any external command that prints one `name value` line per cookie. The original `my_cookies` is such a command and covers Chrome-family browsers (their cookies are AES-encrypted and impractical to read directly). |

Sources are tried in order; the first one that yields cookies wins.  A failing
or empty source is skipped silently.

The direct read uses an embedded Python 3 script (standard library only).
Why Python?  The browser holds a lock on `cookies.sqlite` while running, and
Emacs' built-in sqlite module cannot open it in read-only `immutable` mode.
The script opens the database with
`sqlite3.connect("file:...?immutable=1", uri=True)`, which bypasses the lock.

## Requirements

- Emacs 28.1+
- [leetcode.el](https://github.com/kaiwk/leetcode.el) (loaded as usual; the override is installed automatically once it loads)
- `python3` on `exec-path` (any Python 3; sqlite3 is standard library) — only
  needed for `:firefox-dir` sources
- The browsers/tools you configure as sources

## Install

Clone / copy this directory somewhere and:

```elisp
(add-to-list 'load-path "~/.emacs.d/lib/leetcode-cookie-source")
(require 'leetcode-cookie-source)
```

Or with use-package:

```elisp
(use-package leetcode-cookie-source
  :load-path "~/.emacs.d/lib/leetcode-cookie-source")
```

That's it — **there is no minor mode to enable**.  Loading the package
registers a `with-eval-after-load` hook, and the override of
`leetcode--cookie-get-all` is installed automatically as soon as leetcode.el
is loaded.  `M-x leetcode`, `leetcode-try`, `leetcode-submit` just work.

## Configuration

The default source chain keeps Zen first, with my_cookies as fallback:

```elisp
;; Default value of leetcode-cookie-source-sources
'((:firefox-dir "~/.config/zen")
  (:command "my_cookies"))
```

Examples:

```elisp
;; LibreWolf first, then Firefox, then Chrome-family via my_cookies
(setq leetcode-cookie-source-sources
      '((:firefox-dir "~/.librewolf")
        (:firefox-dir "~/.mozilla/firefox")
        (:command "my_cookies")))

;; Only Firefox
(setq leetcode-cookie-source-sources
      '((:firefox-dir "~/.mozilla/firefox")))

;; Only the original my_cookies behaviour (no direct reads)
(setq leetcode-cookie-source-sources
      '((:command "my_cookies")))
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `leetcode-cookie-source-sources` | `((:firefox-dir "~/.config/zen") (:command "my_cookies"))` | Ordered cookie source chain |
| `leetcode-cookie-source-python-program` | `"python3"` | Python 3 executable |
| `leetcode-cookie-source-domain` | `"leetcode.com"` | LeetCode domain |

## Troubleshooting

The override installs itself automatically — nothing to enable.  If you need
to temporarily turn it off (e.g. to compare against the original cookie
lookup), use plain functions, not a mode:

| Command | Effect |
| --- | --- |
| `M-x leetcode-cookie-source-disable` | Removes the override.  Called before leetcode.el is loaded, it keeps the override from being installed when it loads. |
| `M-x leetcode-cookie-source-enable` | Installs the override immediately (loading leetcode.el if needed) and clears a previous disable. |

## How it works

1. Loading the package registers a `with-eval-after-load` hook; as soon as
   leetcode.el is loaded, `:override` advice is installed on
   `leetcode--cookie-get-all` automatically (no minor mode to enable).
2. For each source in order:
   - `:firefox-dir` runs an embedded Python script via `call-process-region`
     (stdin, no temp files).  The script locates the default profile via
     `profiles.ini` (Install section wins, mirroring browser_cookie3
     semantics) with a glob fallback, opens `cookies.sqlite` read-only with
     `immutable=1`, and prints one `name value` line per cookie of the
     domain, names deduplicated.
   - `:command` runs the command and parses its `name value` output.
3. The first non-empty result is parsed into the alist shape leetcode.el
   expects.

## Known limitations

- The advice targets a private symbol of leetcode.el
  (`leetcode--cookie-get-all`).  If upstream renames or rewrites that
  function, this package needs a matching update.
- If you log out of LeetCode inside the browser, the package reads the (now
  anonymous) cookies from it and does not fall back to later sources — the
  browser still "has" cookies for the domain.  Log in again, or reorder your
  sources.
- Tested with Zen 1.x (Firefox-based) and leetcode.el 2024-era versions.

## License

GPL-3.0-or-later
