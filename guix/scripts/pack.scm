;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2015, 2017-2023 Ludovic Courtès <ludo@gnu.org>
;;; Copyright © 2017, 2018 Ricardo Wurmus <rekado@elephly.net>
;;; Copyright © 2018 Konrad Hinsen <konrad.hinsen@fastmail.net>
;;; Copyright © 2018 Chris Marusich <cmmarusich@gmail.com>
;;; Copyright © 2018 Efraim Flashner <efraim@flashner.co.il>
;;; Copyright © 2020 Tobias Geerinckx-Rice <me@tobias.gr>
;;; Copyright © 2020, 2021, 2022, 2023 Maxim Cournoyer <maxim.cournoyer@gmail.com>
;;; Copyright © 2020 Eric Bavier <bavier@posteo.net>
;;; Copyright © 2022 Alex Griffin <a@ajgrf.com>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

(define-module (guix scripts pack)
  #:use-module (guix scripts)
  #:use-module (guix ui)
  #:use-module (guix gexp)
  #:use-module ((guix build utils) #:select (%xz-parallel-args))
  #:use-module (guix utils)
  #:use-module (guix store)
  #:use-module ((guix status) #:select (with-status-verbosity))
  #:use-module ((guix self) #:select (make-config.scm))
  #:autoload   (guix inferior) (inferior-package?
                                inferior-package-name
                                inferior-package-version)
  #:use-module (guix monads)
  #:use-module (guix modules)
  #:use-module (guix packages)
  #:use-module (guix profiles)
  #:use-module (guix describe)
  #:use-module (guix derivations)
  #:use-module (guix diagnostics)
  #:use-module (guix search-paths)
  #:use-module (guix build-system gnu)
  #:use-module (guix scripts build)
  #:use-module (guix transformations)
  #:use-module ((guix self) #:select (make-config.scm))
  #:use-module (gnu compression)
  #:use-module (gnu packages)
  #:use-module (gnu packages bootstrap)
  #:use-module ((gnu packages compression) #:hide (zip))
  #:use-module (gnu packages guile)
  #:use-module (gnu packages base)
  #:autoload   (gnu packages package-management) (guix)
  #:autoload   (gnu packages gnupg) (guile-gcrypt)
  #:autoload   (gnu packages guile) (guile2.0-json guile-json)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-35)
  #:use-module (srfi srfi-37)
  #:use-module (ice-9 match)
  #:export (symlink-spec-option-parser

            self-contained-tarball
            debian-archive
            rpm-archive
            docker-image
            squashfs-image

            %formats
            guix-pack))

;; This one is only for use in this module, so don't put it in %compressors.
(define bootstrap-xz
  (compressor "bootstrap-xz" ".xz"
              #~(append (list #+(file-append %bootstrap-coreutils&co "/bin/xz")
                              "-e")
                        (%xz-parallel-args))))

(define not-config?
  ;; Select (guix …) and (gnu …) modules, except (guix config).
  (match-lambda
    (('guix 'config) #f)
    (('guix _ ...) #t)
    (('gnu _ ...) #t)
    (_ #f)))

(define gcrypt-sqlite3&co
  ;; Guile-Gcrypt, Guile-SQLite3, and their propagated inputs.
  (append-map (lambda (package)
                (cons package
                      (match (package-transitive-propagated-inputs package)
                        (((labels packages) ...)
                         packages))))
              (list guile-gcrypt guile-sqlite3)))

(define (store-database items)
  "Return a directory containing a store database where all of ITEMS and their
dependencies are registered."
  (define schema
    (local-file (search-path %load-path
                             "guix/store/schema.sql")))


  (define labels
    (map (lambda (n)
           (string-append "closure" (number->string n)))
         (iota (length items))))

  (define build
    (with-extensions gcrypt-sqlite3&co
      (with-imported-modules `(((guix config) => ,(make-config.scm))
                               ,@(source-module-closure
                                  '((guix build store-copy)
                                    (guix store database))
                                  #:select? not-config?))
        #~(begin
            (use-modules (guix store database)
                         (guix build store-copy)
                         (srfi srfi-1))

            (define (read-closure closure)
              (call-with-input-file closure read-reference-graph))

            (define db-file
              (store-database-file #:state-directory #$output))

            ;; Make sure non-ASCII file names are properly handled.
            (setenv "GUIX_LOCPATH"
                    #+(file-append glibc-utf8-locales "/lib/locale"))
            (setlocale LC_ALL "en_US.utf8")

            (sql-schema #$schema)
            (let ((items (append-map read-closure '#$labels)))
              (with-database db-file db
                (register-items db items
                                #:registration-time %epoch)))))))

  (computed-file "store-database" build
                 #:options `(#:references-graphs ,(zip labels items))))

(define-syntax-rule (define-with-source (variable args ...) body body* ...)
  "Bind VARIABLE to a procedure accepting ARGS defined as BODY, also setting
its source property."
  (begin
    (define (variable args ...)
      body body* ...)
    (eval-when (load eval)
      (set-procedure-property! variable 'source
                               '(define (variable args ...) body body* ...)))))

(define-with-source (manifest->friendly-name manifest)
  "Return a friendly name computed from the entries in MANIFEST, a
<manifest> object."
  (let loop ((names (map manifest-entry-name
                         (manifest-entries manifest))))
    (define str (string-join names "-"))
    (if (< (string-length str) 40)
        str
        (match names
          ((_) str)
          ((names ... _) (loop names))))))

(define (symlink-spec-option-parser opt name arg result)
  "A SRFI-37 option parser for the --symlink option.  The symlink spec accepts
the link file name as its left-hand side value and its target as its
right-hand side value.  The target must be a relative link."
  ;; Note: Using 'string-split' allows us to handle empty
  ;; TARGET (as in "/opt/guile=", meaning that /opt/guile is
  ;; a symlink to the profile) correctly.
  (match (string-split arg #\=)
    ((source target)
     (when (string-prefix? "/" target)
       (raise-exception
        (make-compound-condition
         (formatted-message (G_ "symlink target is absolute: '~a'~%") target)
         (condition
          (&fix-hint (hint (format #f (G_ "The target of the symlink must be
relative rather than absolute, as it is relative to the profile created.
Perhaps the source and target components of the symlink spec were inverted?
Below is a valid example, where the @file{/usr/bin/env} symbolic link is to
target the profile's @file{bin/env} file:
@example
--symlink=/usr/bin/env=bin/env
@end example"))))))))
     (let ((symlinks (assoc-ref result 'symlinks)))
       (alist-cons 'symlinks
                   `((,source -> ,target) ,@symlinks)
                   (alist-delete 'symlinks result eq?))))
    (x
     (leave (G_ "~a: invalid symlink specification~%")
            arg))))

(define (set-utf8-locale profile)
  "Configure the environment to use the \"en_US.utf8\" locale provided by the
GLIBC-UT8-LOCALES package."
  ;; Arrange to not depend on 'glibc-utf8-locales' when using '--bootstrap'.
  (and (or (not (profile? profile))
           (profile-locales? profile))
       #~(begin
           (setenv "GUIX_LOCPATH"
                   #+(file-append glibc-utf8-locales "/lib/locale"))
           (setlocale LC_ALL "en_US.utf8"))))

(define* (populate-profile-root profile
                                #:key (profile-name "guix-profile")
                                target
                                localstatedir?
                                deduplicate?
                                (symlinks '()))
  "Populate the root profile directory with SYMLINKS and a Guix database, when
LOCALSTATEDIR? is set.  When DEDUPLICATE? is true, deduplicate the store
items, which relies on hard links."
  (define database
    (and localstatedir?
         (file-append (store-database (list profile))
                      "/db/db.sqlite")))

  (define bootstrap?
    ;; Whether a '--bootstrap' environment is needed, for testing purposes.
    ;; XXX: Infer that from available info.
    (and (not database) (not (profile-locales? profile))))

  (define (import-module? module)
    ;; Since we don't use deduplication support in 'populate-store', don't
    ;; import (guix store deduplication) and its dependencies, which includes
    ;; Guile-Gcrypt, unless DEDUPLICATE? is #t.  This makes it possible to run
    ;; tests with '--bootstrap'.
    (and (not-config? module)
         (or deduplicate? (not (equal? '(guix store deduplication) module)))))

  (computed-file "profile-directory"
    (with-imported-modules (source-module-closure
                            `((guix build pack)
                              (guix build store-copy)
                              (guix build utils)
                              (guix build union)
                              (gnu build install))
                            #:select? import-module?)
      #~(begin
          (use-modules (guix build pack)
                       (guix build store-copy)
                       (guix build utils)
                       ((guix build union) #:select (relative-file-name))
                       (gnu build install)
                       (srfi srfi-1)
                       (srfi srfi-26)
                       (ice-9 match))

          (define symlink->directives
            ;; Return "populate directives" to make the given symlink and its
            ;; parent directories.
            (match-lambda
              ((source '-> target)
               (let ((target (string-append #$profile "/" target))
                     (parent (dirname source)))
                 ;; Never add a 'directory' directive for "/" so as to
                 ;; preserve its ownership when extracting the archive (see
                 ;; below), and also because this would lead to adding the
                 ;; same entries twice in the tarball.
                 `(,@(if (string=? parent "/")
                         '()
                         `((directory ,parent)))
                   ;; Use a relative file name for compatibility with
                   ;; relocatable packs.
                   (,source -> ,(relative-file-name parent target)))))))

          (define directives
            ;; Fully-qualified symlinks.
            (append-map symlink->directives '#$symlinks))

          ;; Make sure non-ASCII file names are properly handled.
          #+(set-utf8-locale profile)

          ;; Note: there is not much to gain here with deduplication and there
          ;; is the overhead of the '.links' directory, so turn it off by
          ;; default.  Furthermore GNU tar < 1.30 sometimes fails to extract
          ;; tarballs with hard links:
          ;; <http://lists.gnu.org/archive/html/bug-tar/2017-11/msg00009.html>.
          (populate-store (list "profile") #$output
                          #:deduplicate? #$deduplicate?)

          (when #+localstatedir?
            (install-database-and-gc-roots #$output #+database #$profile
                                           #:profile-name #$profile-name))

          ;; Create SYMLINKS.
          (for-each (cut evaluate-populate-directive <> #$output)
                    directives)))
    #:local-build? #f
    #:guile (if bootstrap? %bootstrap-guile (default-guile))
    #:options (list #:references-graphs `(("profile" ,profile))
                    #:target target)))


;;;
;;; Tarball format.
;;;
(define* (self-contained-tarball/builder profile
                                         #:key (profile-name "guix-profile")
                                         target
                                         localstatedir?
                                         deduplicate?
                                         symlinks
                                         compressor
                                         archiver)
  "Return a GEXP that can build a self-contained tarball."

  (define root (populate-profile-root profile
                                      #:profile-name profile-name
                                      #:target target
                                      #:localstatedir? localstatedir?
                                      #:deduplicate? deduplicate?
                                      #:symlinks symlinks))

  (with-imported-modules (source-module-closure '((guix build pack)
                                                  (guix build utils)))
    #~(begin
        (use-modules (guix build pack)
                     (guix build utils))

        ;; Make sure non-ASCII file names are properly handled.
        #+(set-utf8-locale profile)

        (define tar #+(file-append archiver "/bin/tar"))

        (define %root (if #$localstatedir? "." #$root))

        (when #$localstatedir?
          ;; Fix the permission of the Guix database file, which was made
          ;; read-only when copied to the store in populate-profile-root.
          (copy-recursively #$root %root)
          (chmod (string-append %root "/var/guix/db/db.sqlite") #o644))

        (with-directory-excursion %root
          ;; GNU Tar recurses directories by default.  Simply add the whole
          ;; current directory, which contains all the files to be archived.
          ;; This avoids creating duplicate files in the archives that would
          ;; be stored as hard links by GNU Tar.
          (apply invoke tar "-cvf" #$output "."
                 (tar-base-options
                  #:tar tar
                  #:compressor #+(and=> compressor compressor-command)))))))

(define* (self-contained-tarball name profile
                                 #:key target
                                 (profile-name "guix-profile")
                                 deduplicate?
                                 entry-point
                                 (compressor (first %compressors))
                                 localstatedir?
                                 (symlinks '())
                                 (archiver tar)
                                 (extra-options '()))
  "Return a self-contained tarball containing a store initialized with the
closure of PROFILE, a derivation.  The tarball contains /gnu/store; if
LOCALSTATEDIR? is true, it also contains /var/guix, including /var/guix/db
with a properly initialized store database.

SYMLINKS must be a list of (SOURCE -> TARGET) tuples denoting symlinks to be
added to the pack."
  (when entry-point
    (warning (G_ "entry point not supported in the '~a' format~%")
             'tarball))

  (gexp->derivation (string-append name ".tar"
                                   (compressor-extension compressor))
    (self-contained-tarball/builder profile
                                    #:profile-name profile-name
                                    #:target target
                                    #:localstatedir? localstatedir?
                                    #:deduplicate? deduplicate?
                                    #:symlinks symlinks
                                    #:compressor compressor
                                    #:archiver archiver)))


;;;
;;; Singularity.
;;;
(define (singularity-environment-file profile)
  "Return a shell script that defines the environment variables corresponding
to the search paths of PROFILE."
  (define build
    (with-extensions (list guile-gcrypt)
      (with-imported-modules `(((guix config) => ,(make-config.scm))
                               ,@(source-module-closure
                                  `((guix profiles)
                                    (guix search-paths))
                                  #:select? not-config?))
        #~(begin
            (use-modules (guix profiles) (guix search-paths)
                         (ice-9 match))

            (call-with-output-file #$output
              (lambda (port)
                (for-each (match-lambda
                            ((spec . value)
                             (format port "~a=~a~%export ~a~%"
                                     (search-path-specification-variable spec)
                                     value
                                     (search-path-specification-variable spec))))
                          (profile-search-paths #$profile))))))))

  (computed-file "singularity-environment.sh" build))


;;;
;;; SquashFS image format.
;;;
(define* (squashfs-image name profile
                         #:key target
                         (profile-name "guix-profile")
                         (compressor (first %compressors))
                         entry-point
                         localstatedir?
                         (symlinks '())
                         (archiver squashfs-tools)
                         (extra-options '()))
  "Return a squashfs image containing a store initialized with the closure of
PROFILE, a derivation.  The image contains a subset of /gnu/store, empty mount
points for virtual file systems (like procfs), and optional symlinks.

SYMLINKS must be a list of (SOURCE -> TARGET) tuples denoting symlinks to be
added to the pack."
  (define database
    (and localstatedir?
         (file-append (store-database (list profile))
                      "/db/db.sqlite")))

  (define environment
    (singularity-environment-file profile))

  (define symlinks*
    ;; Singularity requires /bin (specifically /bin/sh), so ensure that
    ;; symlink is created.
    (if (find (match-lambda
                (("/bin" . _) #t)
                (_            #f))
              symlinks)
        symlinks
        `(("/bin" -> "bin") ,@symlinks)))

  (define build
    (with-extensions (list guile-gcrypt)
      (with-imported-modules (source-module-closure
                              '((guix build utils)
                                (guix build store-copy)
                                (guix build union)
                                (gnu build install))
                              #:select? not-config?)
        #~(begin
            (use-modules (guix build utils)
                         (guix build store-copy)
                         ((guix build union) #:select (relative-file-name))
                         (gnu build install)
                         (srfi srfi-1)
                         (srfi srfi-26)
                         (ice-9 match))

            (define database #+database)
            (define entry-point #$entry-point)

            (define (mksquashfs args)
              (apply invoke "mksquashfs"
                     `(,@args

                       ;; Do not create a "recovery file" when appending to the
                       ;; file system since it's useless in this case.
                       "-no-recovery"

                       ;; Do not attempt to store extended attributes.
                       ;; See <https://bugs.gnu.org/40043>.
                       "-no-xattrs"

                       ;; Set file times and the file system creation time to
                       ;; one second after the Epoch.
                       "-all-time" "1" "-mkfs-time" "1"

                       ;; Reset all UIDs and GIDs.
                       "-force-uid" "0" "-force-gid" "0")))

            (setenv "PATH" #+(file-append archiver "/bin"))

            ;; We need an empty file in order to have a valid file argument when
            ;; we reparent the root file system.  Read on for why that's
            ;; necessary.
            (with-output-to-file ".empty" (lambda () (display "")))

            ;; Create the squashfs image in several steps.
            ;; Add all store items.  Unfortunately mksquashfs throws away all
            ;; ancestor directories and only keeps the basename.  We fix this
            ;; in the following invocations of mksquashfs.
            (mksquashfs `(,@(map store-info-item
                                 (call-with-input-file "profile"
                                   read-reference-graph))
                          #$environment
                          ,#$output

                          ;; Do not perform duplicate checking because we
                          ;; don't have any dupes.
                          "-no-duplicates"
                          "-comp"
                          ,#+(compressor-name compressor)))

            ;; Here we reparent the store items.  For each sub-directory of
            ;; the store prefix we need one invocation of "mksquashfs".
            (for-each (lambda (dir)
                        (mksquashfs `(".empty"
                                      ,#$output
                                      "-root-becomes" ,dir)))
                      (reverse (string-tokenize (%store-directory)
                                                (char-set-complement (char-set #\/)))))

            ;; Add symlinks and mount points.
            (mksquashfs
             `(".empty"
               ,#$output
               ;; Create SYMLINKS via pseudo file definitions.
               ,@(append-map
                  (match-lambda
                    ((source '-> target)
                     ;; Create relative symlinks to work around a bug in
                     ;; Singularity 2.x:
                     ;;   https://bugs.gnu.org/34913
                     ;;   https://github.com/sylabs/singularity/issues/1487
                     (let ((target (string-append #$profile "/" target)))
                       (list "-p"
                             (string-join
                              ;; name s mode uid gid symlink
                              (list source
                                    "s" "777" "0" "0"
                                    (relative-file-name (dirname source)
                                                        target)))))))
                  '#$symlinks*)

               "-p" "/.singularity.d d 555 0 0"

               ;; Create the environment file.
               "-p" "/.singularity.d/env d 555 0 0"
               "-p" ,(string-append
                      "/.singularity.d/env/90-environment.sh s 777 0 0 "
                      (relative-file-name "/.singularity.d/env"
                                          #$environment))

               ;; Create /.singularity.d/actions, and optionally the 'run'
               ;; script, used by 'singularity run'.
               "-p" "/.singularity.d/actions d 555 0 0"

               ,@(if entry-point
                     `( ;; This one if for Singularity 2.x.
                       "-p"
                       ,(string-append
                         "/.singularity.d/actions/run s 777 0 0 "
                         (relative-file-name "/.singularity.d/actions"
                                             (string-append #$profile "/"
                                                            entry-point)))

                       ;; This one is for Singularity 3.x.
                       "-p"
                       ,(string-append
                         "/.singularity.d/runscript s 777 0 0 "
                         (relative-file-name "/.singularity.d"
                                             (string-append #$profile "/"
                                                            entry-point))))
                     '())

               ;; Create empty mount points.
               "-p" "/proc d 555 0 0"
               "-p" "/sys d 555 0 0"
               "-p" "/dev d 555 0 0"
               "-p" "/home d 555 0 0"))

            (when database
              ;; Initialize /var/guix.
              (install-database-and-gc-roots "var-etc" database #$profile)
              (mksquashfs `("var-etc" ,#$output)))))))

  (gexp->derivation (string-append name
                                   (compressor-extension compressor)
                                   ".squashfs")
                    build
                    #:target target
                    #:references-graphs `(("profile" ,profile))))


;;;
;;; Docker image format.
;;;
(define* (docker-image name profile
                       #:key target
                       (profile-name "guix-profile")
                       (compressor (first %compressors))
                       entry-point
                       localstatedir?
                       (symlinks '())
                       (archiver tar)
                       (extra-options '()))
  "Return a derivation to construct a Docker image of PROFILE.  The
image is a tarball conforming to the Docker Image Specification, compressed
with COMPRESSOR.  It can be passed to 'docker load'.  If TARGET is true, it
must a be a GNU triplet and it is used to derive the architecture metadata in
the image."
  (define database
    (and localstatedir?
         (file-append (store-database (list profile))
                      "/db/db.sqlite")))

  (define defmod 'define-module)        ;trick Geiser

  (define build
    ;; Guile-JSON and Guile-Gcrypt are required by (guix docker).
    (with-extensions (list guile-json-3 guile-gcrypt)
      (with-imported-modules `(((guix config) => ,(make-config.scm))
                               ,@(source-module-closure
                                  `((guix docker)
                                    (guix build store-copy)
                                    (guix build utils) ;for %xz-parallel-args
                                    (guix profiles)
                                    (guix search-paths))
                                  #:select? not-config?))
        #~(begin
            (use-modules (guix docker) (guix build store-copy)
                         (guix build utils)
                         (guix profiles) (guix search-paths)
                         (srfi srfi-1) (srfi srfi-19)
                         (ice-9 match))

            #$(procedure-source manifest->friendly-name)

            (define environment
              (map (match-lambda
                     ((spec . value)
                      (cons (search-path-specification-variable spec)
                            value)))
                   (profile-search-paths #$profile)))

            (define symlink->directives
              ;; Return "populate directives" to make the given symlink and its
              ;; parent directories.
              (match-lambda
                ((source '-> target)
                 (let ((target (string-append #$profile "/" target))
                       (parent (dirname source)))
                   `((directory ,parent)
                     (,source -> ,target))))))

            (define directives
              ;; Create a /tmp directory, as some programs expect it, and
              ;; create SYMLINKS.
              `((directory "/tmp" ,(getuid) ,(getgid) #o1777)
                ,@(append-map symlink->directives '#$symlinks)))

            (setenv "PATH" #+(file-append archiver "/bin"))

            (build-docker-image #$output
                                (map store-info-item
                                     (call-with-input-file "profile"
                                       read-reference-graph))
                                #$profile
                                #:repository (manifest->friendly-name
                                              (profile-manifest #$profile))
                                #:database #+database
                                #:system (or #$target %host-type)
                                #:environment environment
                                #:entry-point
                                #$(and entry-point
                                       #~(list (string-append #$profile "/"
                                                              #$entry-point)))
                                #:extra-files directives
                                #:compressor #+(compressor-command compressor)
                                #:creation-time (make-time time-utc 0 1))))))

  (gexp->derivation (string-append name ".tar"
                                   (compressor-extension compressor))
                    build
                    #:target target
                    #:references-graphs `(("profile" ,profile))))


;;;
;;; Debian archive format.
;;;
;;; TODO: When relocatable option is selected, install to a unique prefix.
;;; This would enable installation of multiple deb packs with conflicting
;;; files at the same time.
(define* (debian-archive name profile
                         #:key target
                         (profile-name "guix-profile")
                         deduplicate?
                         entry-point
                         (compressor (first %compressors))
                         localstatedir?
                         (symlinks '())
                         (archiver tar)
                         (extra-options '()))
  "Return a Debian archive (.deb) containing a store initialized with the
closure of PROFILE, a derivation.  The archive contains /gnu/store; if
LOCALSTATEDIR? is true, it also contains /var/guix, including /var/guix/db
with a properly initialized store database.  The supported compressors are
\"none\", \"gz\" or \"xz\".

SYMLINKS must be a list of (SOURCE -> TARGET) tuples denoting symlinks to be
added to the pack.  EXTRA-OPTIONS may contain the CONFIG-FILE, POSTINST-FILE
or TRIGGERS-FILE keyword arguments."
  ;; For simplicity, limit the supported compressors to the superset of
  ;; compressors able to compress both the control file (gz or xz) and the
  ;; data tarball (gz, bz2 or xz).
  (define %valid-compressors '("gzip" "xz" "none"))

  (let ((compressor-name (compressor-name compressor)))
    (unless (member compressor-name %valid-compressors)
      (leave (G_ "~a is not a valid Debian archive compressor.  \
Valid compressors are: ~a~%") compressor-name %valid-compressors)))

  (when entry-point
    (warning (G_ "entry point not supported in the '~a' format~%")
             'deb))

  (define data-tarball
    (computed-file (string-append "data.tar" (compressor-extension
                                              compressor))
      (self-contained-tarball/builder profile
                                      #:target target
                                      #:profile-name profile-name
                                      #:localstatedir? localstatedir?
                                      #:deduplicate? deduplicate?
                                      #:symlinks symlinks
                                      #:compressor compressor
                                      #:archiver archiver)
      #:local-build? #f                 ;allow offloading
      #:options (list #:references-graphs `(("profile" ,profile))
                      #:target target)))

  (define build
    (with-extensions (list guile-gcrypt)
      (with-imported-modules `(((guix config) => ,(make-config.scm))
                               ,@(source-module-closure
                                  `((guix build pack)
                                    (guix build utils)
                                    (guix profiles))
                                  #:select? not-config?))
        #~(begin
            (use-modules (guix build pack)
                         (guix build utils)
                         (guix profiles)
                         (ice-9 match)
                         (ice-9 optargs)
                         (srfi srfi-1))

            (define machine-type
              ;; Extract the machine type from the specified target, else from the
              ;; current system.
              (and=> (or #$target %host-type)
                     (lambda (triplet)
                       (first (string-split triplet #\-)))))

            (define (gnu-machine-type->debian-machine-type type)
              "Translate machine TYPE from the GNU to Debian terminology."
              ;; Debian has its own jargon, different from the one used in GNU, for
              ;; machine types (see data/cputable in the sources of dpkg).
              (match type
                ("i486" "i386")
                ("i586" "i386")
                ("i686" "i386")
                ("x86_64" "amd64")
                ("aarch64" "arm64")
                ("mipsisa32r6" "mipsr6")
                ("mipsisa32r6el" "mipsr6el")
                ("mipsisa64r6" "mips64r6")
                ("mipsisa64r6el" "mips64r6el")
                ("powerpcle" "powerpcel")
                ("powerpc64" "ppc64")
                ("powerpc64le" "ppc64el")
                (machine machine)))

            (define architecture
              (gnu-machine-type->debian-machine-type machine-type))

            #$(procedure-source manifest->friendly-name)

            (define manifest (profile-manifest #$profile))

            (define single-entry        ;manifest entry
              (match (manifest-entries manifest)
                ((entry)
                 entry)
                (_ #f)))

            (define package-name (or (and=> single-entry manifest-entry-name)
                                     (manifest->friendly-name manifest)))

            (define package-version
              (or (and=> single-entry manifest-entry-version)
                  "0.0.0"))

            (define debian-format-version "2.0")

            ;; Generate the debian-binary file.
            (call-with-output-file "debian-binary"
              (lambda (port)
                (format port "~a~%" debian-format-version)))

            (define data-tarball-file-name (strip-store-file-name
                                            #+data-tarball))

            (copy-file #+data-tarball data-tarball-file-name)

            ;; Generate the control archive.
            (let-keywords '#$extra-options #f
                          ((control-file #f)
                           (postinst-file #f)
                           (triggers-file #f))

              (define control-tarball-file-name
                (string-append "control.tar"
                               #$(compressor-extension compressor)))

              ;; Write the compressed control tarball.  Only the control file is
              ;; mandatory (see: 'man deb' and 'man deb-control').
              (if control-file
                  (copy-file control-file "control")
                  (call-with-output-file "control"
                    (lambda (port)
                      (format port "\
Package: ~a
Version: ~a
Description: Debian archive generated by GNU Guix.
Maintainer: GNU Guix
Architecture: ~a
Priority: optional
Section: misc
~%" package-name package-version architecture))))

              (when postinst-file
                (copy-file postinst-file "postinst")
                (chmod "postinst" #o755))

              (when triggers-file
                (copy-file triggers-file "triggers"))

              (define tar (string-append #+archiver "/bin/tar"))

              (apply invoke tar
                     `(,@(tar-base-options
                          #:tar tar
                          #:compressor #+(and=> compressor compressor-command))
                       "-cvf" ,control-tarball-file-name
                       "control"
                       ,@(if postinst-file '("postinst") '())
                       ,@(if triggers-file '("triggers") '())))

              ;; Create the .deb archive using GNU ar.
              (invoke (string-append #+binutils "/bin/ar") "-rv" #$output
                      "debian-binary"
                      control-tarball-file-name data-tarball-file-name))))))

  (gexp->derivation (string-append name ".deb") build))


;;;
;;; RPM archive format.
;;;
(define* (rpm-archive name profile
                      #:key target
                      (profile-name "guix-profile")
                      entry-point
                      (compressor (first %compressors))
                      deduplicate?
                      localstatedir?
                      (symlinks '())
                      archiver
                      (extra-options '()))
  "Return a RPM archive (.rpm) containing a store initialized with the closure
of PROFILE, a derivation.  The archive contains /gnu/store.  SYMLINKS must be
a list of (SOURCE -> TARGET) tuples denoting symlinks to be added to the pack.
ARCHIVER and ENTRY-POINT are not used.  RELOCATABLE?, PREIN-FILE, POSTIN-FILE,
PREUN-FILE and POSTUN-FILE can be provided via EXTRA-OPTIONS."
  (when entry-point
    (warning (G_ "entry point not supported in the '~a' format~%") 'rpm))

  (define root (populate-profile-root profile
                                      #:profile-name profile-name
                                      #:target target
                                      #:localstatedir? localstatedir?
                                      #:deduplicate? deduplicate?
                                      #:symlinks symlinks))

  (define payload
    (let* ((raw-cpio-file-name "payload.cpio")
           (compressed-cpio-file-name (string-append raw-cpio-file-name
                                                     (compressor-extension
                                                      compressor))))
      (computed-file compressed-cpio-file-name
        (with-imported-modules (source-module-closure
                                '((guix build utils)
                                  (guix cpio)
                                  (guix rpm)))
          #~(begin
              (use-modules (guix build utils)
                           (guix cpio)
                           (guix rpm)
                           (srfi srfi-1))

              ;; Make sure non-ASCII file names are properly handled.
              #+(set-utf8-locale profile)

              (define %root (if #$localstatedir? "." #$root))

              (when #$localstatedir?
                ;; Fix the permission of the Guix database file, which was made
                ;; read-only when copied to the store in populate-profile-root.
                (copy-recursively #$root %root)
                (chmod (string-append %root "/var/guix/db/db.sqlite") #o644))

              (call-with-output-file #$raw-cpio-file-name
                (lambda (port)
                  (with-directory-excursion %root
                    ;; The first "." entry is discarded.
                    (write-cpio-archive
                     (remove fhs-directory?
                             (cdr (find-files "." #:directories? #t)))
                     port))))
              (when #+(compressor-command compressor)
                (apply invoke (append #+(compressor-command compressor)
                                      (list #$raw-cpio-file-name))))
              (copy-file #$compressed-cpio-file-name #$output)))
        #:local-build? #f)))            ;allow offloading

  (define build
    (with-extensions (list guile-gcrypt)
      (with-imported-modules `(((guix config) => ,(make-config.scm))
                               ,@(source-module-closure
                                  `((gcrypt hash)
                                    (guix build utils)
                                    (guix profiles)
                                    (guix rpm))
                                  #:select? not-config?))
        #~(begin
            (use-modules (gcrypt hash)
                         (guix build utils)
                         (guix profiles)
                         (guix rpm)
                         (ice-9 binary-ports)
                         (ice-9 match)  ;for manifest->friendly-name
                         (ice-9 optargs)
                         (rnrs bytevectors)
                         (srfi srfi-1))

            ;; Make sure non-ASCII file names are properly handled.
            #+(set-utf8-locale profile)

            (define machine-type
              (and=> (or #$target %host-type)
                     (lambda (triplet)
                       (first (string-split triplet #\-)))))

            #$(procedure-source manifest->friendly-name)

            (define manifest (profile-manifest #$profile))

            (define single-entry        ;manifest entry
              (match (manifest-entries manifest)
                ((entry)
                 entry)
                (_ #f)))

            (define name
              (or (and=> single-entry manifest-entry-name)
                  (manifest->friendly-name manifest)))

            (define version
              (or (and=> single-entry manifest-entry-version) "0.0.0"))

            (define lead
              (generate-lead (string-append name "-" version)
                             #:target (or #$target %host-type)))

            (define payload-digest
              (bytevector->hex-string (file-sha256 #$payload)))

            (let-keywords '#$extra-options #f ((relocatable? #f)
                                               (prein-file #f)
                                               (postin-file #f)
                                               (preun-file #f)
                                               (postun-file #f))

              (let ((header (generate-header name version
                                             payload-digest
                                             #$root
                                             #$(compressor-name compressor)
                                             #:target (or #$target %host-type)
                                             #:relocatable? relocatable?
                                             #:prein-file prein-file
                                             #:postin-file postin-file
                                             #:preun-file preun-file
                                             #:postun-file postun-file)))

                (define header-sha256
                  (bytevector->hex-string (sha256 (u8-list->bytevector header))))

                (define payload-size (stat:size (stat #$payload)))

                (define header+compressed-payload-size
                  (+ (length header) payload-size))

                (define signature
                  (generate-signature header-sha256
                                      header+compressed-payload-size))

                ;; Serialize the archive components to a file.
                (call-with-input-file #$payload
                  (lambda (in)
                    (call-with-output-file #$output
                      (lambda (out)
                        (put-bytevector out (assemble-rpm-metadata lead
                                                                   signature
                                                                   header))
                        (sendfile out in payload-size)))))))))))

  (gexp->derivation (string-append name ".rpm") build))

  
;;;
;;; Compiling C programs.
;;;

;; A C compiler.  That lowers to a single program that can be passed typical C
;; compiler flags, and it makes sure the whole toolchain is available.
(define-record-type <c-compiler>
  (%c-compiler toolchain guile)
  c-compiler?
  (toolchain c-compiler-toolchain)
  (guile     c-compiler-guile))

(define* (c-compiler #:optional inputs
                     #:key (guile (default-guile)))
  (%c-compiler inputs guile))

(define (bootstrap-c-compiler)
  "Return the C compiler that uses the bootstrap toolchain.  This is used only
by '--bootstrap', for testing purposes."
  (define bootstrap-toolchain
    (list (first (assoc-ref (%bootstrap-inputs) "gcc"))
          (first (assoc-ref (%bootstrap-inputs) "binutils"))
          (first (assoc-ref (%bootstrap-inputs) "libc"))))

  (c-compiler bootstrap-toolchain
              #:guile %bootstrap-guile))

(define-gexp-compiler (c-compiler-compiler (compiler <c-compiler>) system target)
  "Lower COMPILER to a single script that does the right thing."
  (define toolchain
    (or (c-compiler-toolchain compiler)
        (list (first (assoc-ref (standard-packages) "gcc"))
              (first (assoc-ref (standard-packages) "ld-wrapper"))
              (first (assoc-ref (standard-packages) "binutils"))
              (first (assoc-ref (standard-packages) "libc"))
              (gexp-input (first (assoc-ref (standard-packages) "libc"))
                          "static"))))

  (define inputs
    (match (append-map package-propagated-inputs
                       (filter package? toolchain))
      (((labels things . _) ...)
       (append toolchain things))))

  (define search-paths
    (cons $PATH
          (append-map package-native-search-paths
                      (filter package? inputs))))

  (define run
    (with-imported-modules (source-module-closure
                            '((guix build utils)
                              (guix search-paths)))
      #~(begin
          (use-modules (guix build utils) (guix search-paths)
                       (ice-9 match))

          (define (output-file args)
            (let loop ((args args))
              (match args
                (() "a.out")
                (("-o" file _ ...) file)
                ((head rest ...) (loop rest)))))

          (set-search-paths (map sexp->search-path-specification
                                 '#$(map search-path-specification->sexp
                                         search-paths))
                            '#$inputs)

          (let ((output (output-file (command-line))))
            (apply invoke "gcc" (cdr (command-line)))
            (invoke "strip" output)))))

  (when target
    ;; TODO: Yep, we'll have to do it someday!
    (leave (G_ "cross-compilation not implemented here;
please email '~a'~%")
           (@ (guix config) %guix-bug-report-address)))

  (gexp->script "c-compiler" run
                #:guile (c-compiler-guile compiler)))


;;;
;;; Wrapped package.
;;;

(define* (wrapped-package package
                          #:optional
                          (output* "out")
                          (compiler (c-compiler))
                          #:key proot?)
  "Return the OUTPUT of PACKAGE with its binaries wrapped such that they are
relocatable.  When PROOT? is true, include PRoot in the result and use it as a
last resort for relocation."
  (define runner
    (local-file (search-auxiliary-file "run-in-namespace.c")))

  (define audit-source
    (local-file (search-auxiliary-file "pack-audit.c")))

  (define (proot)
    (specification->package "proot-static"))

  (define (fakechroot-library)
    (computed-file "libfakechroot.so"
                   #~(copy-file #$(file-append
                                   (specification->package "fakechroot")
                                   "/lib/fakechroot/libfakechroot.so")
                                #$output)))

  (define (audit-module)
    ;; Return an ld.so audit module for use by the 'fakechroot' execution
    ;; engine that translates file names of all the files ld.so loads.
    (computed-file "pack-audit.so"
                   (with-imported-modules '((guix build utils))
                     #~(begin
                         (use-modules (guix build utils))

                         (copy-file #$audit-source "audit.c")
                         (substitute* "audit.c"
                           (("@STORE_DIRECTORY@")
                            (%store-directory)))

                         (invoke #$compiler "-std=gnu99"
                                 "-shared" "-fPIC" "-Os" "-g0"
                                 "-Wall" "audit.c" "-o" #$output)))))

  (define build
    (with-imported-modules (source-module-closure
                            '((guix build utils)
                              (guix build union)
                              (guix build gremlin)
                              (guix elf)))
      #~(begin
          (use-modules (guix build utils)
                       ((guix build union) #:select (symlink-relative))
                       (guix elf)
                       (guix build gremlin)
                       (ice-9 binary-ports)
                       (ice-9 ftw)
                       (ice-9 match)
                       (ice-9 receive)
                       (srfi srfi-1)
                       (rnrs bytevectors))

          (define input
            ;; The OUTPUT* output of PACKAGE.
            (ungexp package output*))

          (define target
            ;; The output we are producing.
            (ungexp output output*))

          (define (strip-store-prefix file)
            ;; Given a file name like "/gnu/store/…-foo-1.2/bin/foo", return
            ;; "/bin/foo".
            (let* ((len  (string-length (%store-directory)))
                   (base (string-drop file (+ 1 len))))
              (match (string-index base #\/)
                (#f    base)
                (index (string-drop base index)))))

          (define (elf-interpreter elf)
            ;; Return the interpreter of ELF as a string, or #f if ELF has no
            ;; interpreter segment.
            (match (find (lambda (segment)
                           (= (elf-segment-type segment) PT_INTERP))
                         (elf-segments elf))
              (#f #f)                             ;maybe a .so
              (segment
               (let ((bv (make-bytevector (- (elf-segment-memsz segment) 1))))
                 (bytevector-copy! (elf-bytes elf)
                                   (elf-segment-offset segment)
                                   bv 0 (bytevector-length bv))
                 (utf8->string bv)))))

          (define (runpath file)
            ;; Return the RUNPATH of FILE as a list of directories.
            (let* ((bv      (call-with-input-file file get-bytevector-all))
                   (elf     (parse-elf bv))
                   (dyninfo (elf-dynamic-info elf)))
              (or (and=> dyninfo elf-dynamic-info-runpath)
                  '())))

          (define (elf-loader-compile-flags program)
            ;; Return the cpp flags defining macros for the ld.so/fakechroot
            ;; wrapper of PROGRAM.

            ;; TODO: Handle scripts by wrapping their interpreter.
            (if (elf-file? program)
                (let* ((bv      (call-with-input-file program
                                  get-bytevector-all))
                       (elf     (parse-elf bv))
                       (interp  (elf-interpreter elf))
                       (gconv   (and interp
                                     (string-append (dirname interp)
                                                    "/gconv"))))
                  (if interp
                      (list (string-append "-DPROGRAM_INTERPRETER=\""
                                           interp "\"")
                            (string-append "-DFAKECHROOT_LIBRARY=\""
                                           #$(fakechroot-library) "\"")

                            (string-append "-DLOADER_AUDIT_MODULE=\""
                                           #$(audit-module) "\"")

                            ;; XXX: Normally (runpath #$(audit-module)) is
                            ;; enough.  However, to work around
                            ;; <https://sourceware.org/bugzilla/show_bug.cgi?id=26634>
                            ;; (glibc <= 2.32), pass the whole search path of
                            ;; PROGRAM, which presumably is a superset of that
                            ;; of the audit module.
                            (string-append "-DLOADER_AUDIT_RUNPATH={ "
                                           (string-join
                                            (map object->string
                                                 (runpath program))
                                            ", " 'suffix)
                                           "NULL }")
                            (if gconv
                                (string-append "-DGCONV_DIRECTORY=\""
                                               gconv "\"")
                                "-UGCONV_DIRECTORY"))
                      '()))
                '()))

          (define (build-wrapper program)
            ;; Build a user-namespace wrapper for PROGRAM.
            (format #t "building wrapper for '~a'...~%" program)
            (copy-file #$runner "run.c")

            (substitute* "run.c"
              (("@WRAPPED_PROGRAM@") program)
              (("@STORE_DIRECTORY@") (%store-directory)))

            (let* ((base   (strip-store-prefix program))
                   (result (string-append target base))
                   (proot  #$(and proot?
                                  #~(string-drop
                                     #$(file-append (proot) "/bin/proot")
                                     (+ (string-length (%store-directory))
                                        1)))))
              (mkdir-p (dirname result))
              (apply invoke #$compiler "-std=gnu99" "-static" "-Os" "-g0" "-Wall"
                     "run.c" "-o" result
                     (string-append "-DWRAPPER_PROGRAM=\""
                                    (canonicalize-path (dirname result)) "/"
                                    (basename result) "\"")
                     (append (if proot
                                 (list (string-append "-DPROOT_PROGRAM=\""
                                                      proot "\""))
                                 '())
                             (elf-loader-compile-flags program)))
              (delete-file "run.c")))

          (setvbuf (current-output-port) 'line)

          ;; Link the top-level files of PACKAGE so that search paths are
          ;; properly defined in PROFILE/etc/profile.
          (mkdir target)
          (for-each (lambda (file)
                      (unless (member file '("." ".." "bin" "sbin" "libexec"))
                        (symlink-relative (string-append input  "/" file)
                                          (string-append target "/" file))))
                    (scandir input))

          (receive (executables others)
              (partition executable-file?
			 ;; Note: Trailing slash in case these are symlinks.
                         (append (find-files (string-append input "/bin/"))
                                 (find-files (string-append input "/sbin/"))
                                 (find-files (string-append input "/libexec/"))))
            ;; Wrap only executables, since the wrapper will eventually need
            ;; to execve them.  E.g. git's "libexec" directory contains many
            ;; shell scripts that are source'd from elsewhere, which fails if
            ;; they are wrapped.
            (for-each build-wrapper executables)
            ;; Link any other non-executable files
            (for-each (lambda (old)
                        (let ((new (string-append target (strip-store-prefix old))))
                          (mkdir-p (dirname new))
                          (symlink-relative old new)))
                      others)))))

  (computed-file (string-append
                  (cond ((package? package)
                         (package-full-name package "-"))
                        ((inferior-package? package)
                         (string-append (inferior-package-name package)
                                        "-"
                                        (inferior-package-version package)))
                        (else "wrapper"))
                  "R")
                 build))

(define (wrapped-manifest-entry entry . args)
  (manifest-entry
    (inherit entry)
    (item (apply wrapped-package
                 (manifest-entry-item entry)
                 (manifest-entry-output entry)
                 args))
    (dependencies (map (lambda (entry)
                         (apply wrapped-manifest-entry entry args))
                       (manifest-entry-dependencies entry)))))


;;;
;;; Command-line options.
;;;

(define %default-options
  ;; Alist of default option values.
  `((format . tarball)
    (profile-name . "guix-profile")
    (system . ,(%current-system))
    (substitutes? . #t)
    (offload? . #t)
    (graft? . #t)
    (print-build-trace? . #t)
    (print-extended-build-trace? . #t)
    (multiplexed-build-output? . #t)
    (debug . 0)
    (verbosity . 1)
    (symlinks . ())
    (compressor . ,(first %compressors))))

(define %formats
  ;; Supported pack formats.
  `((tarball . ,self-contained-tarball)
    (squashfs . ,squashfs-image)
    (docker  . ,docker-image)
    (deb . ,debian-archive)
    (rpm . ,rpm-archive)))

(define (show-formats)
  ;; Print the supported pack formats.
  (display (G_ "The supported formats for 'guix pack' are:"))
  (newline)
  (display (G_ "
  tarball       Self-contained tarball, ready to run on another machine"))
  (display (G_ "
  squashfs      Squashfs image suitable for Singularity"))
  (display (G_ "
  docker        Tarball ready for 'docker load'"))
  (display (G_ "
  deb           Debian archive installable via dpkg/apt"))
  (display (G_ "
  rpm           RPM archive installable via rpm/yum"))
  (newline))

(define (required-option symbol)
  "Return an SYMBOL option that requires a value."
  (option (list (symbol->string symbol)) #t #f
          (lambda (opt name arg result . rest)
            (apply values
                   (alist-cons symbol arg result)
                   rest))))

(define %deb-format-options
  (list (required-option 'control-file)
        (required-option 'postinst-file)
        (required-option 'triggers-file)))

(define (show-deb-format-options)
  (display (G_ "
      --help-deb-format  list options specific to the deb format")))

(define (show-deb-format-options/detailed)
  (display (G_ "
      --control-file=FILE
                         Embed the provided control FILE"))
  (display (G_ "
      --postinst-file=FILE
                         Embed the provided postinst script"))
  (display (G_ "
      --triggers-file=FILE
                         Embed the provided triggers FILE"))
  (newline)
  (exit 0))

(define %rpm-format-options
  (list (required-option 'prein-file)
        (required-option 'postin-file)
        (required-option 'preun-file)
        (required-option 'postun-file)))

(define (show-rpm-format-options)
  (display (G_ "
      --help-rpm-format  list options specific to the RPM format")))

(define (show-rpm-format-options/detailed)
  (display (G_ "
      --prein-file=FILE
                         Embed the provided prein script"))
  (display (G_ "
      --postin-file=FILE
                         Embed the provided postin script"))
  (display (G_ "
      --preun-file=FILE
                         Embed the provided preun script"))
  (display (G_ "
      --postun-file=FILE
                         Embed the provided postun script"))
  (newline)
  (exit 0))

(define %options
  ;; Specifications of the command-line options.
  (cons* (option '(#\h "help") #f #f
                 (lambda args
                   (show-help)
                   (exit 0)))
         (option '(#\V "version") #f #f
                 (lambda args
                   (show-version-and-exit "guix pack")))

         (option '(#\n "dry-run") #f #f
                 (lambda (opt name arg result)
                   (alist-cons 'dry-run? #t result)))
         (option '(#\d "derivation") #f #f
                 (lambda (opt name arg result)
                   (alist-cons 'derivation-only? #t result)))

         (option '(#\f "format") #t #f
                 (lambda (opt name arg result)
                   (alist-cons 'format (string->symbol arg) result)))
         (option '("list-formats") #f #f
                 (lambda args
                   (show-formats)
                   (exit 0)))
         (option '(#\R "relocatable") #f #f
                 (lambda (opt name arg result)
                   (match (assq-ref result 'relocatable?)
                     (#f
                      (alist-cons 'relocatable? #t result))
                     (_
                      (alist-cons 'relocatable? 'proot
                                  (alist-delete 'relocatable? result))))))
         (option '(#\e "expression") #t #f
                 (lambda (opt name arg result)
                   (alist-cons 'expression arg result)))
         (option '(#\m "manifest") #t #f
                 (lambda (opt name arg result)
                   (alist-cons 'manifest arg result)))
         (option '("entry-point") #t #f
                 (lambda (opt name arg result)
                   (alist-cons 'entry-point arg result)))
         (option '(#\C "compression") #t #f
                 (lambda (opt name arg result)
                   (alist-cons 'compressor (lookup-compressor arg)
                               result)))
         (option '(#\S "symlink") #t #f symlink-spec-option-parser)
         (option '("save-provenance") #f #f
                 (lambda (opt name arg result)
                   (alist-cons 'save-provenance? #t result)))
         (option '("localstatedir") #f #f
                 (lambda (opt name arg result)
                   (alist-cons 'localstatedir? #t result)))
         (option '("profile-name") #t #f
                 (lambda (opt name arg result)
                   (match arg
                     ((or "guix-profile" "current-guix")
                      (alist-cons 'profile-name arg result))
                     (_
                      (leave (G_ "~a: unsupported profile name~%") arg)))))
         (option '(#\r "root") #t #f
                 (lambda (opt name arg result)
                   (alist-cons 'gc-root arg result)))

         (option '(#\v "verbosity") #t #f
                 (lambda (opt name arg result)
                   (let ((level (string->number* arg)))
                     (alist-cons 'verbosity level
                                 (alist-delete 'verbosity result)))))
         (option '("bootstrap") #f #f
                 (lambda (opt name arg result)
                   (alist-cons 'bootstrap? #t result)))

         (option '("help-deb-format") #f #f
                 (lambda args
                   (show-deb-format-options/detailed)))

         (option '("help-rpm-format") #f #f
                 (lambda args
                   (show-rpm-format-options/detailed)))

         (append %deb-format-options
                 %rpm-format-options
                 %transformation-options
                 %standard-build-options
                 %standard-cross-build-options
                 %standard-native-build-options)))

(define (show-help)
  (display (G_ "Usage: guix pack [OPTION]... PACKAGE...
Create a bundle of PACKAGE.\n"))
  (show-build-options-help)
  (newline)
  (show-cross-build-options-help)
  (newline)
  (show-native-build-options-help)
  (newline)
  (show-transformation-options-help)
  (newline)
  (show-deb-format-options)
  (show-rpm-format-options)
  (newline)
  (display (G_ "
  -f, --format=FORMAT    build a pack in the given FORMAT"))
  (display (G_ "
      --list-formats     list the formats available"))
  (display (G_ "
  -R, --relocatable      produce relocatable executables"))
  (display (G_ "
  -e, --expression=EXPR  consider the package EXPR evaluates to"))
  (display (G_ "
  -C, --compression=TOOL compress using TOOL--e.g., \"lzip\""))
  (display (G_ "
  -S, --symlink=SPEC     create symlinks to the profile according to SPEC"))
  (display (G_ "
  -m, --manifest=FILE    create a pack with the manifest from FILE"))
  (display (G_ "
      --entry-point=PROGRAM
                         use PROGRAM as the entry point of the pack"))
  (display (G_ "
      --save-provenance  save provenance information"))
  (display (G_ "
      --localstatedir    include /var/guix in the resulting pack"))
  (display (G_ "
      --profile-name=NAME
                         populate /var/guix/profiles/.../NAME"))
  (display (G_ "
  -r, --root=FILE        make FILE a symlink to the result, and register it
                         as a garbage collector root"))
  (display (G_ "
  -d, --derivation       return the derivation of the pack"))
  (display (G_ "
  -v, --verbosity=LEVEL  use the given verbosity LEVEL"))
  (display (G_ "
      --bootstrap        use the bootstrap binaries to build the pack"))
  (newline)
  (display (G_ "
  -h, --help             display this help and exit"))
  (display (G_ "
  -V, --version          display version information and exit"))
  (newline)
  (show-bug-report-information))


;;;
;;; Entry point.
;;;

(define-command (guix-pack . args)
  (category development)
  (synopsis "create application bundles")

  (with-error-handling
    (define opts
      (parse-command-line args %options (list %default-options)))

    (define maybe-package-argument
      ;; Given an option pair, return a package, a package/output tuple, or #f.
      (match-lambda
        (('argument . spec)
         (call-with-values
             (lambda ()
               (specification->package+output spec))
           list))
        (('expression . exp)
         (read/eval-package-expression exp))
        (x #f)))

    (define (manifest-from-args store opts)
      (let* ((transform     (options->transformation opts))
             (packages      (map (match-lambda
                                   (((? package? package) output)
                                    (list (transform package) output))
                                   ((? package? package)
                                    (list (transform package) "out")))
                                 (reverse
                                  (filter-map maybe-package-argument opts))))
             (manifests     (filter-map (match-lambda
                                          (('manifest . file) file)
                                          (_ #f))
                                        opts)))
        (define with-provenance
          (if (assoc-ref opts 'save-provenance?)
              (lambda (manifest)
                (map-manifest-entries
                 (lambda (entry)
                   (let ((entry (manifest-entry-with-provenance entry)))
                     (unless (assq 'provenance (manifest-entry-properties entry))
                       (warning (G_ "could not determine provenance of package ~a~%")
                                (manifest-entry-name entry)))
                     entry))
                 manifest))
              identity))

        (with-provenance
         (cond
          ((and (not (null? manifests)) (not (null? packages)))
           (leave (G_ "both a manifest and a package list were given~%")))
          ((not (null? manifests))
           (concatenate-manifests
            (map (lambda (file)
                   (let ((user-module (make-user-module
                                       '((guix profiles) (gnu)))))
                     (load* file user-module)))
                 manifests)))
          (else
           (packages->manifest packages))))))

    (define (process-file-arg opts name)
      ;; Validate that the file exists and return it as a <local-file> object,
      ;; else #f.
      (let ((value (assoc-ref opts name)))
        (match value
          ((and (? string?) (not (? file-exists?)))
           (leave (G_ "file provided with option ~a does not exist: ~a~%")
                  (string-append "--" (symbol->string name)) value))
          ((? string?)
           (local-file value))
          (#f #f))))

    (with-store store
      (with-status-verbosity (assoc-ref opts 'verbosity)
        ;; Set the build options before we do anything else.
        (set-build-options-from-command-line store opts)

        (with-build-handler (build-notifier #:dry-run?
                                            (assoc-ref opts 'dry-run?)
                                            #:verbosity
                                            (assoc-ref opts 'verbosity)
                                            #:use-substitutes?
                                            (assoc-ref opts 'substitutes?))
          (parameterize ((%graft? (assoc-ref opts 'graft?))
                         (%guile-for-build (package-derivation
                                            store
                                            (if (assoc-ref opts 'bootstrap?)
                                                %bootstrap-guile
                                                (default-guile))
                                            (assoc-ref opts 'system)
                                            #:graft? (assoc-ref opts 'graft?))))
            (let* ((derivation? (assoc-ref opts 'derivation-only?))
                   (relocatable? (assoc-ref opts 'relocatable?))
                   (proot?      (eq? relocatable? 'proot))
                   (manifest    (let ((manifest (manifest-from-args store opts)))
                                  ;; Note: We cannot honor '--bootstrap' here because
                                  ;; 'glibc-bootstrap' lacks 'libc.a'.
                                  (if relocatable?
                                      (map-manifest-entries
                                       (cut wrapped-manifest-entry <> #:proot? proot?)
                                       manifest)
                                      manifest)))
                   (pack-format (assoc-ref opts 'format))
                   (extra-options (match pack-format
                                    ('deb
                                     (list #:control-file
                                           (process-file-arg opts 'control-file)
                                           #:postinst-file
                                           (process-file-arg opts 'postinst-file)
                                           #:triggers-file
                                           (process-file-arg opts 'triggers-file)))
                                    ('rpm
                                     (list #:relocatable? relocatable?
                                           #:prein-file
                                           (process-file-arg opts 'prein-file)
                                           #:postin-file
                                           (process-file-arg opts 'postin-file)
                                           #:preun-file
                                           (process-file-arg opts 'preun-file)
                                           #:postun-file
                                           (process-file-arg opts 'postun-file)))
                                    (_ '())))
                   (target      (assoc-ref opts 'target))
                   (bootstrap?  (assoc-ref opts 'bootstrap?))
                   (compressor  (if bootstrap?
                                    bootstrap-xz
                                    (assoc-ref opts 'compressor)))
                   (archiver    (if (equal? pack-format 'squashfs)
                                    squashfs-tools
                                    (if bootstrap?
                                        %bootstrap-coreutils&co
                                        tar)))
                   (symlinks    (assoc-ref opts 'symlinks))
                   (build-image (match (assq-ref %formats pack-format)
                                  ((? procedure? proc) proc)
                                  (#f
                                   (leave (G_ "~a: unknown pack format~%")
                                          pack-format))))
                   (localstatedir? (assoc-ref opts 'localstatedir?))
                   (entry-point    (assoc-ref opts 'entry-point))
                   (profile-name   (assoc-ref opts 'profile-name))
                   (gc-root        (assoc-ref opts 'gc-root))
                   (profile        (profile
                                    (content manifest)

                                    ;; Always produce relative symlinks for
                                    ;; Singularity (see
                                    ;; <https://bugs.gnu.org/34913>).
                                    (relative-symlinks?
                                     (or relocatable?
                                         (eq? 'squashfs pack-format)))

                                    (hooks (if bootstrap?
                                               '()
                                               %default-profile-hooks))
                                    (locales? (not bootstrap?))))
                   (name (string-append (manifest->friendly-name manifest)
                                        "-" (symbol->string pack-format)
                                        "-pack")))
              (define (lookup-package package)
                (manifest-lookup manifest (manifest-pattern (name package))))

              (when (null? (manifest-entries manifest))
                (warning (G_ "no packages specified; building an empty pack~%")))

              (when (and (eq? pack-format 'squashfs)
                         (not (any lookup-package '("bash" "bash-minimal"))))
                (warning (G_ "Singularity requires you to provide a shell~%"))
                (display-hint (G_ "Add @code{bash} or @code{bash-minimal} \
to your package list.")))

              (run-with-store store
                (mlet* %store-monad ((drv (build-image name profile
                                                       #:target
                                                       target
                                                       #:compressor
                                                       compressor
                                                       #:symlinks
                                                       symlinks
                                                       #:localstatedir?
                                                       localstatedir?
                                                       #:entry-point
                                                       entry-point
                                                       #:profile-name
                                                       profile-name
                                                       #:archiver
                                                       archiver
                                                       #:extra-options
                                                       extra-options)))
                  (mbegin %store-monad
                    (mwhen derivation?
                      (return (format #t "~a~%"
                                      (derivation-file-name drv))))
                    (munless derivation?
                      (built-derivations (list drv))
                      (mwhen gc-root
                        (register-root* (match (derivation->output-paths drv)
                                          (((names . items) ...)
                                           items))
                                        gc-root))
                      (return (format #t "~a~%"
                                      (derivation->output-path drv))))))
                #:target target
                #:system (assoc-ref opts 'system)))))))))
