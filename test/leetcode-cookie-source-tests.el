;;; leetcode-cookie-source-tests.el --- Tests for leetcode-cookie-source  -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'leetcode-cookie-source)

;;; Parsing

(ert-deftest leetcode-cookie-source-parse-basic ()
  (should (equal (leetcode-cookie-source--parse-cookie-output "a 1\nb 2\n")
                 '(("a" "1") ("b" "2")))))

(ert-deftest leetcode-cookie-source-parse-value-with-space ()
  (should (equal (leetcode-cookie-source--parse-cookie-output
                  "ip_check (false, \"1.2.3.4\")\n")
                 '(("ip_check" "(false, \"1.2.3.4\")")))))

(ert-deftest leetcode-cookie-source-parse-empty-output ()
  (should-not (leetcode-cookie-source--parse-cookie-output ""))
  (should-not (leetcode-cookie-source--parse-cookie-output " \n\n")))

(ert-deftest leetcode-cookie-source-parse-malformed-lines-ignored ()
  (should-not (leetcode-cookie-source--parse-cookie-output "no-space-line\n"))
  (should (equal (leetcode-cookie-source--parse-cookie-output "junk\nok 1\n")
                 '(("ok" "1")))))

;;; Source dispatch

(ert-deftest leetcode-cookie-source-firefox-dir-passes-profile-dir ()
  (cl-letf (((symbol-function 'leetcode-cookie-source--run-python)
             (lambda (_script args)
               (should (equal (cadr (member "--profile-dir" args))
                              (expand-file-name "~/.config/zen")))
               (should (equal (cadr (member "--domain" args))
                              "leetcode.com"))
               "LEETCODE_SESSION s\n")))
    (should (equal (leetcode-cookie-source--source-cookies
                    '(:firefox-dir "~/.config/zen"))
                   '(("LEETCODE_SESSION" "s"))))))

(ert-deftest leetcode-cookie-source-command-uses-executable-find ()
  (cl-letf (((symbol-function 'executable-find)
             (lambda (cmd) (should (equal cmd "my_cookies")) "/fake/my_cookies"))
            ((symbol-function 'shell-command-to-string)
             (lambda (path) (should (equal path "/fake/my_cookies")) "a 1\n")))
    (should (equal (leetcode-cookie-source--source-cookies
                    '(:command "my_cookies"))
                   '(("a" "1"))))))

(ert-deftest leetcode-cookie-source-command-not-found-is-nil ()
  (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
    (should-not (leetcode-cookie-source--source-cookies
                 '(:command "no-such-cmd")))))

(ert-deftest leetcode-cookie-source-source-error-is-swallowed ()
  (cl-letf (((symbol-function 'leetcode-cookie-source--command-cookies)
             (lambda (_) (error "boom"))))
    (should-not (leetcode-cookie-source--source-cookies
                 '(:command "whatever")))))

;;; Source chain semantics

(ert-deftest leetcode-cookie-source-chain-first-nonempty-wins ()
  (let ((leetcode-cookie-source-sources
         '((:command "first") (:command "second")))
        (calls 0))
    (cl-letf (((symbol-function 'leetcode-cookie-source--source-cookies)
               (lambda (source)
                 (cl-incf calls)
                 (pcase source
                   (`(:command "first") '(("csrftoken" "first")))
                   (`(:command "second") '(("csrftoken" "second")))))))
      (should (equal (leetcode-cookie-source--cookie-get-all)
                     '(("csrftoken" "first"))))
      ;; The second source must not be consulted.
      (should (= calls 1)))))

(ert-deftest leetcode-cookie-source-chain-skips-empty ()
  (let ((leetcode-cookie-source-sources
         '((:command "first") (:command "second"))))
    (cl-letf (((symbol-function 'leetcode-cookie-source--source-cookies)
               (lambda (source)
                 (pcase source
                   (`(:command "first") nil)
                   (`(:command "second") '(("csrftoken" "second")))))))
      (should (equal (leetcode-cookie-source--cookie-get-all)
                     '(("csrftoken" "second")))))))

(ert-deftest leetcode-cookie-source-chain-all-empty-is-nil ()
  (let ((leetcode-cookie-source-sources
         '((:command "first") (:command "second"))))
    (cl-letf (((symbol-function 'leetcode-cookie-source--source-cookies)
               (lambda (_) nil)))
      (should-not (leetcode-cookie-source--cookie-get-all)))))

;;; Embedded Python script

(ert-deftest leetcode-cookie-source-python-script-compiles ()
  (skip-unless (executable-find leetcode-cookie-source-python-program))
  (let ((tmp (make-temp-file "leetcode-cookie-source" nil ".py")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert leetcode-cookie-source--python-script))
          (should (eq 0 (call-process leetcode-cookie-source-python-program
                                      nil nil nil
                                      "-m" "py_compile" tmp))))
      (delete-file tmp))))

(ert-deftest leetcode-cookie-source-python-script-runs-without-profile ()
  (skip-unless (executable-find leetcode-cookie-source-python-program))
  (let ((output (leetcode-cookie-source--run-python
                 leetcode-cookie-source--python-script
                 (list "-" "--profile-dir" "/nonexistent-profile-dir"
                       "--domain" "leetcode.com"))))
    (should output)
    (should (equal output ""))))

;;; Activation lifecycle

(ert-deftest leetcode-cookie-source-enable-disable-roundtrip ()
  (let ((leetcode-cookie-source--installed nil)
        (leetcode-cookie-source--disabled nil))
    (unless (fboundp 'leetcode--cookie-get-all)
      (defalias 'leetcode--cookie-get-all
        (lambda () '(("stub" "1")))))
    (cl-letf (((symbol-function 'require)
               (lambda (feature) (should (eq feature 'leetcode)))))
      (unwind-protect
          (progn
            (leetcode-cookie-source-enable)
            (should leetcode-cookie-source--installed)
            (should (advice-member-p
                     #'leetcode-cookie-source--cookie-get-all
                     'leetcode--cookie-get-all))
            (leetcode-cookie-source-disable)
            (should-not leetcode-cookie-source--installed)
            (should leetcode-cookie-source--disabled)
            (should-not (advice-member-p
                         #'leetcode-cookie-source--cookie-get-all
                         'leetcode--cookie-get-all)))
        (leetcode-cookie-source-disable)))))

(ert-deftest leetcode-cookie-source-maybe-enable-respects-disabled ()
  (let ((leetcode-cookie-source--installed nil))
    (unless (fboundp 'leetcode--cookie-get-all)
      (defalias 'leetcode--cookie-get-all
        (lambda () '(("stub" "1")))))
    (unwind-protect
        (progn
          (let ((leetcode-cookie-source--disabled t))
            (leetcode-cookie-source--maybe-enable))
          (should-not leetcode-cookie-source--installed)
          (should-not (advice-member-p
                       #'leetcode-cookie-source--cookie-get-all
                       'leetcode--cookie-get-all)))
      (leetcode-cookie-source-disable))))

(ert-deftest leetcode-cookie-source-enable-clears-disabled ()
  (let ((leetcode-cookie-source--installed nil)
        (leetcode-cookie-source--disabled t))
    (unless (fboundp 'leetcode--cookie-get-all)
      (defalias 'leetcode--cookie-get-all
        (lambda () '(("stub" "1")))))
    (cl-letf (((symbol-function 'require) (lambda (_feature))))
      (unwind-protect
          (progn
            (leetcode-cookie-source-enable)
            (should-not leetcode-cookie-source--disabled)
            (should leetcode-cookie-source--installed))
        (leetcode-cookie-source-disable)))))

;;; Real Zen integration (skipped when no Zen profile exists)

(ert-deftest leetcode-cookie-source-real-zen-integration ()
  (skip-unless (and (executable-find leetcode-cookie-source-python-program)
                    (file-directory-p "~/.config/zen")))
  (let ((pairs (leetcode-cookie-source--firefox-dir-cookies
                "~/.config/zen")))
    (should pairs)
    (should (assoc "LEETCODE_SESSION" pairs))
    (should (assoc "csrftoken" pairs))))

;;; leetcode-cookie-source-tests.el ends here
