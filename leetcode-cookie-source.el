;;; leetcode-cookie-source.el --- Configurable browser cookie sources for leetcode.el  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kazure

;; Author: kazure
;; Version: 0.2.0
;; Package-Requires: ((emacs "28.1") (leetcode "0.0.1"))
;; Keywords: tools
;; URL: https://github.com/kazure/leetcode-cookie-source

;;; Commentary:

;; Configurable browser cookie sources for leetcode.el.
;;
;; The my_cookies tool used by leetcode.el relies on browser_cookie3,
;; which does not know the Zen browser (profiles live under
;; ~/.config/zen, not ~/.mozilla/firefox), and always returns the
;; first browser jar it finds, even when the session inside is stale.
;; As a result leetcode-try and leetcode-submit fail when the user is
;; logged in via Zen or another browser my_cookies mishandles.
;;
;; This package overrides `leetcode--cookie-get-all' with a
;; user-configurable, ordered chain of cookie sources.  Each source is
;; either:
;;
;;   (:firefox-dir DIR)  -- any Firefox-family browser profile
;;                          directory (Zen, LibreWolf, Waterfox,
;;                          Firefox).  Cookies are read straight from
;;                          cookies.sqlite through an embedded Python 3
;;                          script (standard library only).  The browser
;;                          holds a lock on the database while running,
;;                          so the script opens it with sqlite3's
;;                          immutable=1 read-only mode.
;;
;;   (:command CMD)      -- any external command that prints one
;;                          `name value' line per cookie.  The original
;;                          my_cookies is such a command and covers
;;                          Chrome-family browsers (whose cookies are
;;                          AES-encrypted and impractical to read
;;                          directly).
;;
;; Sources are tried in order; the first one that yields cookies wins.
;; A failing or empty source is skipped silently.
;;
;; Usage:
;;
;;   (require 'leetcode-cookie-source)
;;   (leetcode-cookie-source-mode 1)
;;
;; The default source chain keeps the Zen-first behaviour:
;;
;;   ((:firefox-dir "~/.config/zen")
;;    (:command "my_cookies"))
;;
;; Example for other browsers:
;;
;;   (setq leetcode-cookie-source-sources
;;         '((:firefox-dir "~/.librewolf")
;;           (:firefox-dir "~/.mozilla/firefox")
;;           (:command "my_cookies")))

;;; Code:

(require 'cl-lib)

(defgroup leetcode-cookie-source nil
  "Configurable browser cookie sources for leetcode.el."
  :group 'leetcode)

(defcustom leetcode-cookie-source-python-program "python3"
  "Python 3 executable used to read Firefox-family cookie databases.
The script only uses the standard library (sqlite3, argparse,
configparser, glob)."
  :group 'leetcode-cookie-source
  :type 'string)

(defcustom leetcode-cookie-source-domain "leetcode.com"
  "LeetCode domain whose cookies should be retrieved."
  :group 'leetcode-cookie-source
  :type 'string)

(defcustom leetcode-cookie-source-sources
  '((:firefox-dir "~/.config/zen")
    (:command "my_cookies"))
  "Ordered list of cookie sources to try.
Each element is a plist with one of these shapes:

  (:firefox-dir DIR)  -- read cookies directly from the
                         cookies.sqlite of a Firefox-family browser
                         profile directory DIR (Zen, LibreWolf,
                         Waterfox, Firefox).

  (:command CMD)      -- run the external command CMD (found via
                         `executable-find') and parse its output as
                         one `name value' line per cookie.  The
                         original my_cookies tool is an example and
                         covers Chrome-family browsers.

Sources are tried in order; the first non-empty result wins."
  :group 'leetcode-cookie-source
  :type '(repeat
          (choice
           (list :tag "Firefox-family profile directory"
                 (const :firefox-dir)
                 directory)
           (list :tag "External command"
                 (const :command)
                 string))))

(defconst leetcode-cookie-source--python-script
  "import argparse
import configparser
import glob
import os
import sqlite3

def cookie_files(profile_dir):
    files = sorted(glob.glob(os.path.join(profile_dir, '**', 'cookies.sqlite'),
                             recursive=True))
    if not files:
        return files
    ini = os.path.join(profile_dir, 'profiles.ini')
    default = None
    if os.path.isfile(ini):
        try:
            cp = configparser.ConfigParser()
            cp.read(ini, encoding='utf8')
            # Mirror browser_cookie3 semantics: an Install section's
            # Default wins over Default=1 sections.
            for section in cp.sections():
                if section.startswith('Install'):
                    default = cp[section].get('Default')
                    break
                if cp[section].get('Default') == '1' and not default:
                    default = cp[section].get('Path')
        except Exception:
            default = None
    if default:
        target = os.path.join(profile_dir, default, 'cookies.sqlite')
        if target in files:
            files.remove(target)
        files.insert(0, target)
    return files

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--profile-dir',
                        default=os.path.expanduser('~/.config/zen'))
    parser.add_argument('--domain', default='leetcode.com')
    args = parser.parse_args()
    profile_dir = os.path.expanduser(args.profile_dir)
    for path in cookie_files(profile_dir):
        if not os.path.isfile(path):
            continue
        try:
            # immutable=1: read-only view that bypasses the lock the
            # browser holds on cookies.sqlite while running.
            db = sqlite3.connect('file:%s?immutable=1' % path, uri=True)
            try:
                rows = db.execute('select name, value from moz_cookies '
                                  'where host like ?',
                                  ('%' + args.domain + '%',)).fetchall()
            finally:
                db.close()
        except sqlite3.Error:
            continue
        if rows:
            seen = {}
            for name, value in rows:
                seen[name] = value
            for name in sorted(seen):
                print(name, seen[name])
            return

if __name__ == '__main__':
    main()
"
  "Embedded Python script that reads cookies from a Firefox-family
cookies.sqlite.  Prints one `name value' line per cookie for the
requested domain.  Exits silently (empty output, status 0) when the
profile directory is absent or has no cookie for the domain.")

(defun leetcode-cookie-source--run-python (script args)
  "Run SCRIPT with `leetcode-cookie-source-python-program' and ARGS.
Return stdout as a string on success, nil otherwise."
  (with-temp-buffer
    (insert script)
    (let* ((out (generate-new-buffer " *leetcode-cookie-source-output*"))
           (status (apply #'call-process-region
                          (point-min) (point-max)
                          leetcode-cookie-source-python-program
                          nil out nil
                          args)))
      (unwind-protect
          (and (eq status 0)
               (with-current-buffer out
                 (buffer-string)))
        (kill-buffer out)))))

(defun leetcode-cookie-source--parse-cookie-output (output)
  "Parse OUTPUT lines of \"name value\" into an alist of (NAME VALUE) lists.
Compatible with the return format of leetcode.el's
`leetcode--cookie-get-all'."
  (let (pairs)
    (dolist (line (split-string output "\n" t) (nreverse pairs))
      (when (string-match "\\`\\([^ ]+\\) \\(.*\\)\\'" line)
        (push (list (match-string 1 line) (match-string 2 line))
              pairs)))))

(defun leetcode-cookie-source--firefox-dir-cookies (dir)
  "Read LeetCode cookies from Firefox-family profile directory DIR.
Return an alist of (NAME VALUE) lists, or nil when the directory is
absent or has no cookie for `leetcode-cookie-source-domain'."
  (when (file-directory-p (expand-file-name dir))
    (let ((output (leetcode-cookie-source--run-python
                   leetcode-cookie-source--python-script
                   (list "-"
                         "--profile-dir"
                         (expand-file-name dir)
                         "--domain"
                         leetcode-cookie-source-domain))))
      (and output (leetcode-cookie-source--parse-cookie-output output)))))

(defun leetcode-cookie-source--command-cookies (cmd)
  "Run external command CMD and parse its `name value' output.
Return an alist of (NAME VALUE) lists, or nil when the command is not
found or produced no cookies."
  (when-let ((path (executable-find cmd)))
    (leetcode-cookie-source--parse-cookie-output
     (shell-command-to-string path))))

(defun leetcode-cookie-source--source-cookies (source)
  "Get cookies from SOURCE, a plist element of
`leetcode-cookie-source-sources'.  Return an alist or nil."
  (condition-case nil
      (pcase source
        (`(:firefox-dir ,dir)
         (leetcode-cookie-source--firefox-dir-cookies dir))
        (`(:command ,cmd)
         (leetcode-cookie-source--command-cookies cmd)))
    (error nil)))

(defun leetcode-cookie-source--cookie-get-all ()
  "Get LeetCode cookies from the configured source chain.
Tries `leetcode-cookie-source-sources' in order and returns the first
non-empty result."
  (cl-some #'leetcode-cookie-source--source-cookies
           leetcode-cookie-source-sources))

;;;###autoload
(define-minor-mode leetcode-cookie-source-mode
  "Toggle configurable browser cookie sources for leetcode.el.

When enabled, `leetcode--cookie-get-all' is overridden to read
cookies from the ordered source chain in
`leetcode-cookie-source-sources'."
  :global t
  :group 'leetcode-cookie-source
  (if leetcode-cookie-source-mode
      (progn
        (require 'leetcode)
        (advice-add 'leetcode--cookie-get-all :override
                    #'leetcode-cookie-source--cookie-get-all))
    (advice-remove 'leetcode--cookie-get-all
                   #'leetcode-cookie-source--cookie-get-all)))

(provide 'leetcode-cookie-source)
;;; leetcode-cookie-source.el ends here
