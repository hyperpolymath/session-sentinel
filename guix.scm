; SPDX-License-Identifier: MPL-2.0
;; guix.scm — GNU Guix package definition for session-sentinel
;; Usage: guix shell -f guix.scm

(use-modules (guix packages)
             (guix build-system gnu)
             (guix licenses))

(package
  (name "session-sentinel")
  (version "0.1.0")
  (source #f)
  (build-system gnu-build-system)
  (synopsis "session-sentinel")
  (description "session-sentinel — part of the hyperpolymath ecosystem.")
  (home-page "https://github.com/hyperpolymath/session-sentinel")
  (license mpl2.0))
